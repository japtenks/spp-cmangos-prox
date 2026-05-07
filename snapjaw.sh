#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/snapjaw.env"

LAUNCHER_VERSION="snapjaw-tortoise-lxc-1"
DEFAULT_TORTOISE_REPO_URL="https://github.com/japtenks/tortoise-wow.git"
DEFAULT_TORTOISE_GIT_BRANCH="main"
DEFAULT_REALM_DB_NAME="snapjawrealmd"
DEFAULT_INSTALL_DIR="/opt/snapjaw"
DEFAULT_SOURCE_DIR="/opt/tortoise-wow"
DEFAULT_BUILD_DIR="/opt/tortoise-wow-build"
DEFAULT_DATA_DIR="/opt/snapjaw/data"

DB_CTID=""
REALMD_CTID=""
declare -A WORLD_CTIDS
EXPANSION="tortoise"
WORLD_CTID=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

pause() {
  read -r -p "Press Enter to continue..." _
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

set_config_line() {
  local key="$1"
  local value="$2"

  touch "$CONFIG_FILE"
  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$CONFIG_FILE"
  fi
}

quote_config_value() {
  local value="${1//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

persist_world_names() {
  local rendered=""
  local name

  for name in "${TORTOISE_WORLD_NAMES[@]}"; do
    [[ -n "$name" ]] || continue
    rendered="${rendered} \"${name}\""
  done

  set_config_line "TORTOISE_WORLD_NAMES" "(${rendered# })"
}

render_world_names_config() {
  local rendered=""
  local name

  for name in "${TORTOISE_WORLD_NAMES[@]}"; do
    [[ -n "$name" ]] || continue
    rendered="${rendered} $(quote_config_value "$name")"
  done

  printf '(%s)' "${rendered# }"
}

normalize_world_name() {
  local value="$1"
  value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//; s/-$//')
  [[ -n "$value" ]] || value="tortoise"
  if [[ "$value" == "stable" ]]; then
    value="tortoise"
  elif [[ "$value" != "tortoise" && "$value" != tortoise-* ]]; then
    value="tortoise-${value}"
  fi
  printf '%s' "$value"
}

world_token() {
  local name="${1:-$EXPANSION}"
  name="${name#tortoise}"
  name="${name#-}"
  [[ -n "$name" ]] || name="stable"
  printf '%s' "$name" | tr -cd '[:alnum:]'
}

world_hostname() {
  local name="${1:-$EXPANSION}"
  if [[ "$name" == "tortoise" ]]; then
    printf '%s' "spp-tortoise"
  else
    printf 'spp-%s' "$name"
  fi
}

world_title() {
  local name="${1:-$EXPANSION}"
  if [[ "$name" == "tortoise" ]]; then
    printf '%s' "SnapJaw Tortoise"
  else
    printf 'SnapJaw %s' "${name#tortoise-}"
  fi
}

derive_db_names() {
  local token
  token=$(world_token "$EXPANSION")
  WORLD_DB="${token}mangos"
  CHAR_DB_NAME="${token}characters"
  LOG_DB_NAME="${token}logs"
  REALM_DB_NAME="${SNAPJAW_REALM_DB_NAME:-$DEFAULT_REALM_DB_NAME}"
  REALM_ID=1

  local index=1
  local name
  for name in "${TORTOISE_WORLD_NAMES[@]}"; do
    if [[ "$name" == "$EXPANSION" ]]; then
      REALM_ID="$index"
      break
    fi
    index=$((index + 1))
  done
}

print_banner() {
  clear
  echo "########################################"
  echo "# SnapJaw - Tortoise WoW LXC Launcher"
  echo "########################################"
  cat <<'SNAPJAW_LOGO'
   _____                    __
  / ___/____  ____ _____   / /___ __      __
  \__ \/ __ \/ __ `/ __ \ / / __ `/ | /| / /
 ___/ / / / / /_/ / /_/ // / /_/ /| |/ |/ /
/____/_/ /_/\__,_/ .___//_/\__,_/ |__/|__/
                /_/
SNAPJAW_LOGO
  echo "Repo:   ${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}"
  echo "Branch: ${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}"
  echo "Version: ${LAUNCHER_VERSION}"
  echo
}

ensure_config_defaults() {
  TORTOISE_REPO_URL="${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}"
  TORTOISE_GIT_BRANCH="${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}"
  SNAPJAW_REALM_DB_NAME="${SNAPJAW_REALM_DB_NAME:-$DEFAULT_REALM_DB_NAME}"
  INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
  SOURCE_DIR="${SOURCE_DIR:-$DEFAULT_SOURCE_DIR}"
  BUILD_DIR="${BUILD_DIR:-$DEFAULT_BUILD_DIR}"
  DATA_DIR="${DATA_DIR:-$DEFAULT_DATA_DIR}"
  NETWORK_MODE="${NETWORK_MODE:-dhcp}"
  NET_BRIDGE="${NET_BRIDGE:-vmbr0}"
  NET_GW="${NET_GW:-}"
  DB_PORT="${DB_PORT:-3306}"
  DB_LAN_HOST="${DB_LAN_HOST:-%}"
  DB_LAN_USER="${DB_LAN_USER:-mangos}"
  MARIADB_CORES="${MARIADB_CORES:-2}"
  MARIADB_RAM="${MARIADB_RAM:-4096}"
  MARIADB_DISK="${MARIADB_DISK:-16}"
  REALMD_CORES="${REALMD_CORES:-1}"
  REALMD_RAM="${REALMD_RAM:-1024}"
  REALMD_DISK="${REALMD_DISK:-8}"
  WORLD_CORES="${WORLD_CORES:-4}"
  WORLD_RAM="${WORLD_RAM:-16384}"
  WORLD_DISK="${WORLD_DISK:-32}"
  IP_DB="${IP_DB:-}"
  IP_REALMD="${IP_REALMD:-}"
  IP_TORTOISE="${IP_TORTOISE:-}"
  TORTOISE_DATA_SOURCE="${TORTOISE_DATA_SOURCE:-}"
  DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"
  DEFAULT_TEMPLATE="${DEFAULT_TEMPLATE:-}"

  if ! declare -p TORTOISE_WORLD_NAMES >/dev/null 2>&1; then
    TORTOISE_WORLD_NAMES=("tortoise")
  fi
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  ensure_config_defaults
}

write_initial_config() {
  cat > "$CONFIG_FILE" <<EOF
LAUNCHER_VERSION=$(quote_config_value "$LAUNCHER_VERSION")
TORTOISE_REPO_URL=$(quote_config_value "$TORTOISE_REPO_URL")
TORTOISE_GIT_BRANCH=$(quote_config_value "$TORTOISE_GIT_BRANCH")
SNAPJAW_REALM_DB_NAME=$(quote_config_value "$SNAPJAW_REALM_DB_NAME")
TORTOISE_WORLD_NAMES=$(render_world_names_config)

DB_ROOT_PASS=$(quote_config_value "$DB_ROOT_PASS")
DB_LAN_USER=$(quote_config_value "$DB_LAN_USER")
DB_LAN_PASS=$(quote_config_value "$DB_LAN_PASS")
DB_LAN_HOST=$(quote_config_value "$DB_LAN_HOST")
ADMIN_USER=$(quote_config_value "$ADMIN_USER")
ADMIN_PASS=$(quote_config_value "$ADMIN_PASS")

MARIADB_CORES="$MARIADB_CORES"
MARIADB_RAM="$MARIADB_RAM"
MARIADB_DISK="$MARIADB_DISK"
REALMD_CORES="$REALMD_CORES"
REALMD_RAM="$REALMD_RAM"
REALMD_DISK="$REALMD_DISK"
WORLD_CORES="$WORLD_CORES"
WORLD_RAM="$WORLD_RAM"
WORLD_DISK="$WORLD_DISK"

DEFAULT_STORAGE=$(quote_config_value "$DEFAULT_STORAGE")
DEFAULT_TEMPLATE=$(quote_config_value "$DEFAULT_TEMPLATE")
NETWORK_MODE=$(quote_config_value "$NETWORK_MODE")
NET_BRIDGE=$(quote_config_value "$NET_BRIDGE")
NET_GW=$(quote_config_value "$NET_GW")
IP_DB=$(quote_config_value "$IP_DB")
IP_REALMD=$(quote_config_value "$IP_REALMD")
IP_TORTOISE=$(quote_config_value "$IP_TORTOISE")
TORTOISE_DATA_SOURCE=$(quote_config_value "$TORTOISE_DATA_SOURCE")

INSTALL_DIR=$(quote_config_value "$INSTALL_DIR")
SOURCE_DIR=$(quote_config_value "$SOURCE_DIR")
BUILD_DIR=$(quote_config_value "$BUILD_DIR")
DATA_DIR=$(quote_config_value "$DATA_DIR")
DB_PORT="$DB_PORT"
EOF
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

select_storage() {
  local storages=()
  mapfile -t storages < <(pvesm status | awk '$3=="active"{print $1}')
  if [[ ${#storages[@]} -eq 0 ]]; then
    DEFAULT_STORAGE="local-lvm"
    return
  fi

  echo "Select Proxmox storage:"
  select DEFAULT_STORAGE in "${storages[@]}"; do
    [[ -n "$DEFAULT_STORAGE" ]] && break
  done
}

ensure_template_name() {
  if [[ -n "${DEFAULT_TEMPLATE:-}" ]] && pveam list local | awk '{print $1}' | grep -qx "$DEFAULT_TEMPLATE"; then
    return
  fi

  DEFAULT_TEMPLATE=$(pveam list local | awk '/debian-[0-9]+-standard/ && !/testing/ {print $1}' | sort -V | tail -n1)
  if [[ -z "$DEFAULT_TEMPLATE" ]]; then
    echo "Fetching latest Debian template list..."
    pveam update
    DEFAULT_TEMPLATE=$(pveam available | awk '/debian-[0-9]+-standard/ && !/testing/ {print $2}' | sort -V | tail -n1)
    [[ -n "$DEFAULT_TEMPLATE" ]] || die "No Debian LXC template was found."
    pveam download local "$DEFAULT_TEMPLATE"
  fi
}

first_run_config() {
  [[ -f "$CONFIG_FILE" ]] && return 0
  ensure_config_defaults

  print_banner
  echo "No SnapJaw config was found. Gathering first-run Tortoise WoW settings."
  echo

  read -r -s -p "DB root password: " DB_ROOT_PASS; echo
  read -r -p "DB app username [mangos]: " DB_LAN_USER
  DB_LAN_USER="${DB_LAN_USER:-mangos}"
  read -r -s -p "DB app password: " DB_LAN_PASS; echo
  read -r -p "DB app host [%]: " DB_LAN_HOST
  DB_LAN_HOST="${DB_LAN_HOST:-%}"
  read -r -p "Admin username [admin]: " ADMIN_USER
  ADMIN_USER="${ADMIN_USER:-admin}"
  read -r -s -p "Admin password: " ADMIN_PASS; echo
  echo

  read -r -p "World cores [4]: " WORLD_CORES
  WORLD_CORES="${WORLD_CORES:-4}"
  read -r -p "World RAM MB [16384]: " WORLD_RAM
  WORLD_RAM="${WORLD_RAM:-16384}"
  read -r -p "World disk GB [32]: " WORLD_DISK
  WORLD_DISK="${WORLD_DISK:-32}"
  read -r -p "Auth/realmd cores [1]: " REALMD_CORES
  REALMD_CORES="${REALMD_CORES:-1}"
  read -r -p "Auth/realmd RAM MB [1024]: " REALMD_RAM
  REALMD_RAM="${REALMD_RAM:-1024}"
  read -r -p "Auth/realmd disk GB [8]: " REALMD_DISK
  REALMD_DISK="${REALMD_DISK:-8}"
  echo

  select_storage
  ensure_template_name
  echo

  echo "Network mode for SnapJaw containers:"
  echo "  1) DHCP"
  echo "  2) Static IPs"
  read -r -p "Selection [1]: " NET_SEL
  NET_SEL="${NET_SEL:-1}"
  if [[ "$NET_SEL" == "2" ]]; then
    NETWORK_MODE="static"
    read -r -p "Bridge [vmbr0]: " NET_BRIDGE
    NET_BRIDGE="${NET_BRIDGE:-vmbr0}"
    read -r -p "Gateway: " NET_GW
    read -r -p "spp-db IP/CIDR: " IP_DB
    read -r -p "spp-realmd IP/CIDR: " IP_REALMD
    read -r -p "spp-tortoise IP/CIDR: " IP_TORTOISE
  else
    NETWORK_MODE="dhcp"
    NET_BRIDGE="vmbr0"
    NET_GW=""
    IP_DB=""
    IP_REALMD=""
    IP_TORTOISE=""
  fi
  echo

  read -r -p "Default world name [tortoise]: " FIRST_WORLD
  FIRST_WORLD=$(normalize_world_name "${FIRST_WORLD:-tortoise}")
  TORTOISE_WORLD_NAMES=("$FIRST_WORLD")
  read -r -p "Optional extra worlds, comma-separated: " EXTRA_WORLDS
  if [[ -n "${EXTRA_WORLDS:-}" ]]; then
    IFS=',' read -ra EXTRA_WORLD_ITEMS <<< "$EXTRA_WORLDS"
    local item normalized
    for item in "${EXTRA_WORLD_ITEMS[@]}"; do
      normalized=$(normalize_world_name "$item")
      TORTOISE_WORLD_NAMES+=("$normalized")
    done
  fi

  read -r -p "Existing Tortoise client data path for dbc/maps/vmaps/mmaps (blank to stage later): " TORTOISE_DATA_SOURCE
  TORTOISE_REPO_URL="$DEFAULT_TORTOISE_REPO_URL"
  TORTOISE_GIT_BRANCH="$DEFAULT_TORTOISE_GIT_BRANCH"
  SNAPJAW_REALM_DB_NAME="$DEFAULT_REALM_DB_NAME"
  INSTALL_DIR="$DEFAULT_INSTALL_DIR"
  SOURCE_DIR="$DEFAULT_SOURCE_DIR"
  BUILD_DIR="$DEFAULT_BUILD_DIR"
  DATA_DIR="$DEFAULT_DATA_DIR"
  DB_PORT="3306"

  write_initial_config
  echo
  echo "Created ${CONFIG_FILE}."
  pause
}

auto_detect_stack() {
  local pct_rows name ctid
  DB_CTID=""
  REALMD_CTID=""
  WORLD_CTIDS=()

  pct_rows=$(pct list 2>/dev/null || true)
  [[ -n "$pct_rows" ]] || return 0

  DB_CTID=$(awk '$3=="spp-db" {print $1; exit}' <<< "$pct_rows")
  REALMD_CTID=$(awk '$3=="spp-realmd" {print $1; exit}' <<< "$pct_rows")

  local world
  for world in "${TORTOISE_WORLD_NAMES[@]}"; do
    name=$(world_hostname "$world")
    ctid=$(awk -v host="$name" '$3==host {print $1; exit}' <<< "$pct_rows")
    [[ -n "$ctid" ]] && WORLD_CTIDS[$world]="$ctid"
  done

  return 0
}

container_ip_var() {
  case "$1" in
    db) printf '%s' "${IP_DB:-}" ;;
    realmd) printf '%s' "${IP_REALMD:-}" ;;
    world) printf '%s' "${IP_TORTOISE:-}" ;;
    *) printf '%s' "" ;;
  esac
}

create_container() {
  local name="$1"
  local role="$2"
  local ctid="$3"
  local order="$4"
  local cores ram disk ip net_arg

  if pct status "$ctid" >/dev/null 2>&1; then
    echo "CTID ${ctid} already exists. Skipping ${name}."
    return 0
  fi

  case "$role" in
    db) cores="$MARIADB_CORES"; ram="$MARIADB_RAM"; disk="$MARIADB_DISK" ;;
    realmd) cores="$REALMD_CORES"; ram="$REALMD_RAM"; disk="$REALMD_DISK" ;;
    world) cores="$WORLD_CORES"; ram="$WORLD_RAM"; disk="$WORLD_DISK" ;;
    *) die "Unknown container role: $role" ;;
  esac

  ensure_template_name
  ip=$(container_ip_var "$role")
  if [[ "$NETWORK_MODE" == "static" && -n "$ip" ]]; then
    net_arg="name=eth0,bridge=${NET_BRIDGE},ip=${ip},gw=${NET_GW}"
  else
    net_arg="name=eth0,bridge=${NET_BRIDGE:-vmbr0},ip=dhcp"
  fi

  echo "Creating ${name} as CTID ${ctid}..."
  pct create "$ctid" "$DEFAULT_TEMPLATE" \
    --hostname "$name" \
    --cores "$cores" \
    --memory "$ram" \
    --rootfs "${DEFAULT_STORAGE}:${disk}" \
    --net0 "$net_arg" \
    --unprivileged 1 \
    --onboot 1 \
    --startup order="$order" \
    --features nesting=1,keyctl=1

  pct start "$ctid"
  pct exec "$ctid" -- bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y full-upgrade
    apt-get -y install ca-certificates curl wget git rsync nano systemd-sysv
  "
}

ensure_db_container() {
  auto_detect_stack
  [[ -n "$DB_CTID" ]] && return 0
  echo
  pct list || true
  read -r -p "Enter CTID for spp-db: " DB_NEW
  [[ "$DB_NEW" =~ ^[0-9]+$ ]] || die "CTID must be numeric."
  create_container "spp-db" "db" "$DB_NEW" 1
  auto_detect_stack
  [[ -n "$DB_CTID" ]] || die "spp-db was not detected after creation."
}

ensure_realmd_container() {
  auto_detect_stack
  [[ -n "$REALMD_CTID" ]] && return 0
  echo
  pct list || true
  read -r -p "Enter CTID for spp-realmd: " REALMD_NEW
  [[ "$REALMD_NEW" =~ ^[0-9]+$ ]] || die "CTID must be numeric."
  create_container "spp-realmd" "realmd" "$REALMD_NEW" 2
  auto_detect_stack
  [[ -n "$REALMD_CTID" ]] || die "spp-realmd was not detected after creation."
}

ensure_world_container() {
  auto_detect_stack
  WORLD_CTID="${WORLD_CTIDS[$EXPANSION]:-}"
  [[ -n "$WORLD_CTID" ]] && return 0
  echo
  pct list || true
  read -r -p "Enter CTID for $(world_hostname "$EXPANSION"): " WORLD_NEW
  [[ "$WORLD_NEW" =~ ^[0-9]+$ ]] || die "CTID must be numeric."
  create_container "$(world_hostname "$EXPANSION")" "world" "$WORLD_NEW" 3
  auto_detect_stack
  WORLD_CTID="${WORLD_CTIDS[$EXPANSION]:-}"
  [[ -n "$WORLD_CTID" ]] || die "$(world_hostname "$EXPANSION") was not detected after creation."
}

install_db_server() {
  ensure_db_container
  echo "Installing MariaDB in spp-db..."
  pct exec "$DB_CTID" -- bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y install mariadb-server mariadb-client
    systemctl enable mariadb
    systemctl start mariadb
    mariadb -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;\" || true
    sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf || true
    systemctl restart mariadb
  "
}

db_ip() {
  pct exec "$DB_CTID" -- hostname -I | awk '{print $1}'
}

realmd_ip() {
  pct exec "$REALMD_CTID" -- hostname -I | awk '{print $1}'
}

world_ip() {
  pct exec "$WORLD_CTID" -- hostname -I | awk '{print $1}'
}

prepare_world_source() {
  ensure_world_container
  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    if [[ -d '${SOURCE_DIR}/.git' ]]; then
      git -C '${SOURCE_DIR}' remote set-url origin '${TORTOISE_REPO_URL}'
      git -C '${SOURCE_DIR}' fetch origin '${TORTOISE_GIT_BRANCH}'
      git -C '${SOURCE_DIR}' checkout '${TORTOISE_GIT_BRANCH}' || git -C '${SOURCE_DIR}' checkout -B '${TORTOISE_GIT_BRANCH}' 'origin/${TORTOISE_GIT_BRANCH}'
      git -C '${SOURCE_DIR}' reset --hard 'origin/${TORTOISE_GIT_BRANCH}'
      git -C '${SOURCE_DIR}' clean -fd
    else
      rm -rf '${SOURCE_DIR}'
      git clone --branch '${TORTOISE_GIT_BRANCH}' '${TORTOISE_REPO_URL}' '${SOURCE_DIR}'
    fi
  "
}

install_build_deps() {
  ensure_world_container
  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y install \
      build-essential cmake git mariadb-client libmariadb-dev \
      libssl-dev libace-dev libtbb-dev libbz2-dev zlib1g-dev \
      libreadline-dev libncurses-dev libboost-all-dev \
      libcurl4-openssl-dev
  "
}

build_and_install_world_binaries() {
  install_build_deps
  prepare_world_source
  echo "Building Tortoise WoW core in $(world_hostname "$EXPANSION")..."
  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    rm -rf '${BUILD_DIR}'
    cmake -S '${SOURCE_DIR}' -B '${BUILD_DIR}' \
      -DCMAKE_INSTALL_PREFIX='${INSTALL_DIR}' \
      -DCMAKE_BUILD_TYPE=Release \
      -DUSE_EXTRACTORS=OFF
    cmake --build '${BUILD_DIR}' --target install -- -j\$(nproc)
  "
}

sync_data_to_world() {
  ensure_world_container
  pct exec "$WORLD_CTID" -- mkdir -p "$DATA_DIR"

  if [[ -n "${TORTOISE_DATA_SOURCE:-}" && -d "$TORTOISE_DATA_SOURCE" ]]; then
    echo "Syncing Tortoise client data from ${TORTOISE_DATA_SOURCE}..."
    for required in dbc maps vmaps mmaps; do
      [[ -d "${TORTOISE_DATA_SOURCE}/${required}" ]] || die "Missing ${TORTOISE_DATA_SOURCE}/${required}"
    done
    pct push "$WORLD_CTID" "$TORTOISE_DATA_SOURCE" "/tmp/snapjaw-data-source" --recursive 2>/dev/null || {
      echo "pct push --recursive is unavailable; using tar stream fallback."
      tar -C "$TORTOISE_DATA_SOURCE" -cf - . | pct exec "$WORLD_CTID" -- tar -C "$DATA_DIR" -xf -
      return 0
    }
    pct exec "$WORLD_CTID" -- bash -c "rsync -a --delete /tmp/snapjaw-data-source/ '${DATA_DIR}/' && rm -rf /tmp/snapjaw-data-source"
  fi

  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    for required in dbc maps vmaps mmaps; do
      if [[ ! -d '${DATA_DIR}/'\$required ]]; then
        echo 'Missing required data directory: ${DATA_DIR}/'\$required
        echo 'Stage Tortoise client extraction output and run Maintenance -> Sync Data.'
        exit 1
      fi
    done
  "
}

install_tortoise_databases() {
  ensure_db_container
  ensure_world_container
  prepare_world_source
  derive_db_names
  local db_host
  db_host=$(db_ip)

  echo "Installing databases for $(world_title "$EXPANSION")..."
  pct exec "$DB_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root -e \"
      DROP DATABASE IF EXISTS ${WORLD_DB};
      DROP DATABASE IF EXISTS ${CHAR_DB_NAME};
      DROP DATABASE IF EXISTS ${LOG_DB_NAME};
      CREATE DATABASE ${WORLD_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
      CREATE DATABASE ${CHAR_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
      CREATE DATABASE ${LOG_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
      CREATE DATABASE IF NOT EXISTS ${REALM_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
      CREATE USER IF NOT EXISTS '${DB_LAN_USER}'@'${DB_LAN_HOST}' IDENTIFIED BY '${DB_LAN_PASS}';
      GRANT ALL PRIVILEGES ON ${WORLD_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
      GRANT ALL PRIVILEGES ON ${CHAR_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
      GRANT ALL PRIVILEGES ON ${LOG_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
      GRANT ALL PRIVILEGES ON ${REALM_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
      FLUSH PRIVILEGES;
    \"
  "

  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_LAN_PASS}'
    MYSQL_ARGS=(--skip-ssl --host='${db_host}' --port='${DB_PORT}' --user='${DB_LAN_USER}')
    sed \
      -e 's/\\/\\*![0-9]\\{5\\} DEFINER=\`[^\`]*\`@\`[^\`]*\`\\*\\///g' \
      -e 's/\\btw_world\\b/${WORLD_DB}/g' \
      -e 's/\\btw_char\\b/${CHAR_DB_NAME}/g' \
      -e 's/\\btw_logs\\b/${LOG_DB_NAME}/g' \
      -e 's/\\btw_logon\\b/${REALM_DB_NAME}/g' \
      '${SOURCE_DIR}/sql/create_databases.sql' | mariadb \"\${MYSQL_ARGS[@]}\"

    for f in '${SOURCE_DIR}'/sql/base/tw_world_*.sql; do
      [[ -e \"\$f\" ]] || continue
      sed 's/\\btw_world\\b/${WORLD_DB}/g' \"\$f\" | mariadb \"\${MYSQL_ARGS[@]}\" '${WORLD_DB}'
    done
  "

  update_realm_entry
  create_admin_account
}

update_realm_entry() {
  ensure_db_container
  ensure_realmd_container
  ensure_world_container
  derive_db_names
  local address
  address=$(world_ip)

  pct exec "$DB_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root '${REALM_DB_NAME}' -e \"
      DELETE FROM realmlist WHERE id=${REALM_ID};
      INSERT INTO realmlist
        (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel, population, realmbuilds)
      VALUES
        (${REALM_ID}, '$(world_title "$EXPANSION")', '${address}', 8085, 0, 0, 1, 0, 0, '5875')
      ON DUPLICATE KEY UPDATE
        name=VALUES(name), address=VALUES(address), port=VALUES(port), realmbuilds=VALUES(realmbuilds);
    \"
  "
}

create_admin_account() {
  [[ -n "${ADMIN_USER:-}" && -n "${ADMIN_PASS:-}" ]] || return 0
  ensure_world_container
  if ! pct exec "$WORLD_CTID" -- test -x "${INSTALL_DIR}/bin/mangosd"; then
    return 0
  fi

  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    printf 'account create %s %s\naccount set gmlevel %s 3 -1\nserver exit\n' \
      '${ADMIN_USER}' '${ADMIN_PASS}' '${ADMIN_USER}' | '${INSTALL_DIR}/bin/mangosd' -c '${INSTALL_DIR}/etc/mangosd.conf' || true
  "
}

deploy_configs() {
  ensure_db_container
  ensure_realmd_container
  ensure_world_container
  prepare_world_source
  derive_db_names
  local db_host
  db_host=$(db_ip)

  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    mkdir -p '${INSTALL_DIR}/etc' '${DATA_DIR}' '${INSTALL_DIR}/sql'
    rsync -a --delete '${SOURCE_DIR}/sql/' '${INSTALL_DIR}/sql/'
    cp -f '${SOURCE_DIR}/data/etc/mangosd.conf.dist' '${INSTALL_DIR}/etc/mangosd.conf'
    sed -i \
      -e 's|^DataDir *=.*|DataDir = \"${DATA_DIR}\"|' \
      -e 's|^WorldServerPort *=.*|WorldServerPort = 8085|' \
      -e 's|^RealmID *=.*|RealmID = ${REALM_ID}|' \
      -e 's|^LoginDatabase.Info *=.*|LoginDatabase.Info = \"${db_host};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
      -e 's|^WorldDatabase.Info *=.*|WorldDatabase.Info = \"${db_host};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
      -e 's|^CharacterDatabase.Info *=.*|CharacterDatabase.Info = \"${db_host};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
      -e 's|^LoginDatabase.WorkerThreads *=.*|LoginDatabase.WorkerThreads = 1|' \
      -e 's|^WorldDatabase.WorkerThreads *=.*|WorldDatabase.WorkerThreads = 1|' \
      -e 's|^CharacterDatabase.WorkerThreads *=.*|CharacterDatabase.WorkerThreads = 1|' \
      '${INSTALL_DIR}/etc/mangosd.conf'
    if grep -q '^LogsDatabase.Info' '${INSTALL_DIR}/etc/mangosd.conf'; then
      sed -i -e 's|^LogsDatabase.Info *=.*|LogsDatabase.Info = \"${db_host};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' '${INSTALL_DIR}/etc/mangosd.conf'
    fi
  "

  pct exec "$REALMD_CTID" -- bash -c "
    set -euo pipefail
    mkdir -p '${INSTALL_DIR}/etc' '${INSTALL_DIR}/bin'
  "
  pct exec "$WORLD_CTID" -- tar -C "$SOURCE_DIR/data/etc" -cf - realmd.conf.dist | pct exec "$REALMD_CTID" -- tar -C "$INSTALL_DIR/etc" -xf -
  pct exec "$REALMD_CTID" -- bash -c "
    set -euo pipefail
    cp -f '${INSTALL_DIR}/etc/realmd.conf.dist' '${INSTALL_DIR}/etc/realmd.conf'
    sed -i \
      -e 's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${db_host};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
      '${INSTALL_DIR}/etc/realmd.conf'
  "
}

deploy_realmd_binary() {
  ensure_realmd_container
  ensure_world_container
  pct exec "$REALMD_CTID" -- bash -c "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y install mariadb-client libmariadb-dev libssl-dev libace-dev libtbb-dev libbz2-dev zlib1g-dev
  "
  if ! pct exec "$WORLD_CTID" -- test -x "${INSTALL_DIR}/bin/realmd"; then
    die "realmd binary was not found in ${INSTALL_DIR}/bin on $(world_hostname "$EXPANSION")."
  fi

  pct exec "$WORLD_CTID" -- tar -C "$INSTALL_DIR" -cf - bin/realmd | pct exec "$REALMD_CTID" -- tar -C "$INSTALL_DIR" -xf -
}

write_services() {
  ensure_realmd_container
  ensure_world_container
  pct exec "$REALMD_CTID" -- bash -c "
    set -euo pipefail
    cat > /etc/systemd/system/realmd.service <<EOF
[Unit]
Description=SnapJaw Tortoise realmd
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/bin
ExecStart=${INSTALL_DIR}/bin/realmd -c ${INSTALL_DIR}/etc/realmd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable realmd
  "

  pct exec "$WORLD_CTID" -- bash -c "
    set -euo pipefail
    cat > /etc/systemd/system/mangosd.service <<EOF
[Unit]
Description=SnapJaw Tortoise world server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}/bin
ExecStart=${INSTALL_DIR}/bin/mangosd -c ${INSTALL_DIR}/etc/mangosd.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable mangosd
  "
}

full_install_selected_world() {
  ensure_db_container
  ensure_realmd_container
  ensure_world_container
  install_db_server
  build_and_install_world_binaries
  deploy_configs
  sync_data_to_world
  install_tortoise_databases
  deploy_realmd_binary
  write_services
  echo "Install complete for $(world_title "$EXPANSION")."
}

repair_stack() {
  ensure_db_container
  ensure_realmd_container
  ensure_world_container
  install_db_server
  prepare_world_source
  deploy_configs
  deploy_realmd_binary
  write_services
  update_realm_entry
  echo "Stack repair complete."
}

start_stack() {
  auto_detect_stack
  ensure_db_container
  ensure_realmd_container
  ensure_world_container
  pct start "$DB_CTID" 2>/dev/null || true
  pct start "$REALMD_CTID" 2>/dev/null || true
  pct start "$WORLD_CTID" 2>/dev/null || true
  pct exec "$DB_CTID" -- systemctl start mariadb
  pct exec "$REALMD_CTID" -- systemctl start realmd
  pct exec "$WORLD_CTID" -- systemctl start mangosd
}

stop_stack() {
  auto_detect_stack
  WORLD_CTID="${WORLD_CTIDS[$EXPANSION]:-}"
  [[ -n "$WORLD_CTID" ]] && pct exec "$WORLD_CTID" -- systemctl stop mangosd 2>/dev/null || true
  [[ -n "$REALMD_CTID" ]] && pct exec "$REALMD_CTID" -- systemctl stop realmd 2>/dev/null || true
}

status_stack() {
  auto_detect_stack
  echo "spp-db:      ${DB_CTID:-not installed}"
  echo "spp-realmd:  ${REALMD_CTID:-not installed}"
  local world
  for world in "${TORTOISE_WORLD_NAMES[@]}"; do
    echo "$(world_hostname "$world"): ${WORLD_CTIDS[$world]:-not installed}"
  done
}

select_world_menu() {
  while true; do
    print_banner
    auto_detect_stack
    echo "Select World"
    echo
    local i world status
    for i in "${!TORTOISE_WORLD_NAMES[@]}"; do
      world="${TORTOISE_WORLD_NAMES[$i]}"
      status="${WORLD_CTIDS[$world]:-Not installed}"
      [[ "$status" =~ ^[0-9]+$ ]] && status="CTID $status"
      echo "$((i + 1)) - $(world_title "$world") [$status]"
    done
    echo "0 - Back"
    echo
    read -r -p "Selection: " sel
    [[ "$sel" == "0" ]] && return
    [[ "$sel" =~ ^[0-9]+$ ]] || continue
    local index=$((sel - 1))
    if [[ $index -ge 0 && $index -lt ${#TORTOISE_WORLD_NAMES[@]} ]]; then
      EXPANSION="${TORTOISE_WORLD_NAMES[$index]}"
      return
    fi
  done
}

create_world_menu() {
  print_banner
  read -r -p "New world name: " new_world
  new_world=$(normalize_world_name "$new_world")

  local existing
  for existing in "${TORTOISE_WORLD_NAMES[@]}"; do
    if [[ "$existing" == "$new_world" ]]; then
      EXPANSION="$new_world"
      ensure_world_container
      return
    fi
  done

  TORTOISE_WORLD_NAMES+=("$new_world")
  persist_world_names
  EXPANSION="$new_world"
  ensure_world_container
}

edit_configs_menu() {
  ensure_world_container
  echo "1 - Edit mangosd.conf"
  echo "2 - Edit realmd.conf"
  echo "0 - Back"
  read -r -p "Selection: " sel
  case "$sel" in
    1) pct exec "$WORLD_CTID" -- nano "${INSTALL_DIR}/etc/mangosd.conf" ;;
    2) ensure_realmd_container; pct exec "$REALMD_CTID" -- nano "${INSTALL_DIR}/etc/realmd.conf" ;;
  esac
}

remote_console() {
  ensure_world_container
  pct exec "$WORLD_CTID" -- bash -c "systemctl is-active --quiet mangosd && journalctl -u mangosd -f || '${INSTALL_DIR}/bin/mangosd' -c '${INSTALL_DIR}/etc/mangosd.conf'"
}

live_logs() {
  ensure_world_container
  pct exec "$WORLD_CTID" -- journalctl -u mangosd -f
}

server_info() {
  print_banner
  derive_db_names
  status_stack
  echo
  echo "Selected world: $(world_title "$EXPANSION")"
  echo "World DB:       ${WORLD_DB}"
  echo "Characters DB:  ${CHAR_DB_NAME}"
  echo "Logs DB:        ${LOG_DB_NAME}"
  echo "Realm DB:       ${REALM_DB_NAME}"
  echo "Realm ID:       ${REALM_ID}"
  echo "Install dir:    ${INSTALL_DIR}"
  echo "Data dir:       ${DATA_DIR}"
  pause
}

maintenance_menu() {
  while true; do
    print_banner
    echo "Maintenance - $(world_title "$EXPANSION")"
    echo
    echo "1 - Install or Repair Full Stack"
    echo "2 - Reinstall Selected World Databases"
    echo "3 - Build/Reinstall Selected World Core"
    echo "4 - Sync Tortoise Client Data"
    echo "5 - Regenerate Configs and Services"
    echo "6 - Edit Configs"
    echo "0 - Back"
    echo
    read -r -p "Selection: " sel
    case "$sel" in
      1) full_install_selected_world; pause ;;
      2) install_tortoise_databases; pause ;;
      3) build_and_install_world_binaries; deploy_realmd_binary; write_services; pause ;;
      4) sync_data_to_world; pause ;;
      5) deploy_configs; deploy_realmd_binary; write_services; update_realm_entry; pause ;;
      6) edit_configs_menu ;;
      0) return ;;
    esac
  done
}

stack_control_menu() {
  while true; do
    print_banner
    echo "Stack Control - $(world_title "$EXPANSION")"
    echo
    echo "1 - Start"
    echo "2 - Stop"
    echo "3 - Restart"
    echo "4 - Status"
    echo "0 - Back"
    echo
    read -r -p "Selection: " sel
    case "$sel" in
      1) start_stack; pause ;;
      2) stop_stack; pause ;;
      3) stop_stack; start_stack; pause ;;
      4) status_stack; pause ;;
      0) return ;;
    esac
  done
}

prompt_install_if_empty() {
  auto_detect_stack
  if [[ -n "$DB_CTID" || -n "$REALMD_CTID" || -n "${WORLD_CTIDS[$EXPANSION]:-}" ]]; then
    return
  fi

  print_banner
  echo "No SnapJaw Tortoise stack was detected."
  read -r -p "Install Tortoise WoW now? [y/N]: " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    full_install_selected_world
    pause
  fi
}

main_menu() {
  while true; do
    auto_detect_stack
    WORLD_CTID="${WORLD_CTIDS[$EXPANSION]:-}"
    print_banner
    echo "Selected: $(world_title "$EXPANSION")"
    if [[ -n "$WORLD_CTID" ]]; then
      echo "World:    $(world_hostname "$EXPANSION") [CTID ${WORLD_CTID}]"
    else
      echo "World:    $(world_hostname "$EXPANSION") [Not installed]"
    fi
    echo "DB:       ${DB_CTID:-Not installed}"
    echo "Realmd:   ${REALMD_CTID:-Not installed}"
    echo
    echo "1 - Stack Control"
    echo "2 - Maintenance"
    echo "3 - Remote Console"
    echo "4 - Live World Log"
    echo "5 - Server Info"
    echo "S - Select World"
    echo "N - New World"
    echo "I - Install Tortoise WoW"
    echo "0 - Exit"
    echo
    read -r -p "Selection: " sel
    case "$sel" in
      1) stack_control_menu ;;
      2) maintenance_menu ;;
      3) remote_console ;;
      4) live_logs ;;
      5) server_info ;;
      S|s) select_world_menu ;;
      N|n) create_world_menu ;;
      I|i) full_install_selected_world; pause ;;
      0) exit 0 ;;
    esac
  done
}

main() {
  require_cmd pct
  require_cmd pvesm
  require_cmd pveam
  first_run_config
  load_config
  EXPANSION="${TORTOISE_WORLD_NAMES[0]:-tortoise}"
  prompt_install_if_empty
  main_menu
}

main "$@"
