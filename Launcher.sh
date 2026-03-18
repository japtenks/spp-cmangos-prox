#!/bin/bash
set -euo pipefail
trap 'echo "ERROR at line $LINENO: $BASH_COMMAND" >&2' ERR
DRY_RUN=0

# -------------------------
# First Run Bootstrap
# -------------------------
CONFIG_FILE="./config.env"
declare -A GAME_CTIDS

auto_detect_stack() {
  local _pct
  _pct=$(pct list) || return
  DB_CTID=$(awk '$3=="spp-db"    {print $1}' <<< "$_pct") || true
  WEB_CTID=$(awk '$3=="spp-web"  {print $1}' <<< "$_pct") || true
  LOGIN_CTID=$(awk '$3=="spp-login" {print $1}' <<< "$_pct") || true
  local _exp _ct
  for _exp in classic tbc wotlk; do
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
  else
    NETWORK_MODE="dhcp"
    NET_BRIDGE="vmbr0"
    NET_GW=""
    IP_DB="" IP_WEB="" IP_LOGIN=""
    IP_CLASSIC="" IP_TBC="" IP_WOTLK=""
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
ALLOWED_EXPANSIONS=("classic" "tbc" "wotlk")
INSTALLED_EXPANSIONS=()
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
MASTER_EXPANSION=""
EOF
  echo "config.env created."
fi

source "$CONFIG_FILE"

DB_CTID="${DB_CTID:-}"
WEB_CTID="${WEB_CTID:-}"
LOGIN_CTID="${LOGIN_CTID:-}"
GAME_CTID="${GAME_CTID:-}"
EXPANSION=""

declare -A VERSION_MAP
for EXP in classic tbc wotlk; do
  KEY=$(echo "$EXP" | tr '[:lower:]' '[:upper:]')
  for TYPE in WORLD CORE REALM CHARS LOGS MAPS WEBSITE; do
    VAR="${KEY}_${TYPE}_VERSION"
    VERSION_MAP["$EXP:$TYPE"]="${!VAR:-0}"
  done
done


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
        libssl-dev libbz2-dev libreadline-dev \
        libncurses-dev libmariadb-dev libmariadb-dev-compat \
        libboost-all-dev libace-dev unzip wget p7zip-full
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
    *) echo "Unknown expansion: $EXPANSION"; return 1 ;;
  esac

  WORLD_DB="${DB_KEY}mangos"
  CHAR_DB_NAME="${DB_KEY}characters"
  LOG_DB_NAME="${DB_KEY}logs"

  # Realm DB always belongs to master expansion
  # Falls back to current expansion if master not yet set (first install)
  local MASTER="${MASTER_EXPANSION:-$EXPANSION}"
  case "$MASTER" in
    classic) REALM_DB_NAME="classicrealmd" ;;
    tbc)     REALM_DB_NAME="tbcrealmd" ;;
    wotlk)   REALM_DB_NAME="wotlkrealmd" ;;
    *) echo "Unknown master expansion: $MASTER"; return 1 ;;
  esac

  case "$EXPANSION" in
    classic) INSTALL_DIR="/srv/mangos-classic" ;;
    tbc)     INSTALL_DIR="/srv/mangos-tbc" ;;
    wotlk)   INSTALL_DIR="/srv/mangos-wotlk" ;;
  esac

  case "$EXPANSION" in
    classic) REALM_ID=1 ;;
    tbc)     REALM_ID=2 ;;
    wotlk)   REALM_ID=3 ;;
  esac
}

pin_master_expansion() {
  if [[ -z "${MASTER_EXPANSION:-}" ]]; then
    MASTER_EXPANSION="$EXPANSION"
    sed -i "s/^MASTER_EXPANSION=.*/MASTER_EXPANSION=\"$MASTER_EXPANSION\"/" "$CONFIG_FILE"
    echo "Pinned master expansion: $MASTER_EXPANSION"
  else
    echo "Master expansion already pinned: $MASTER_EXPANSION"
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
}

print_banner() {
  local EXP="${EXPANSION:-main}"
  local COLOR LOGO
  local CLEAR="\e[0m"

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
  |____/|_|   |_|roxmox v.2
"
      ;;
  esac

  clear
  echo -e "$COLOR"
  echo "########################################"
  echo "# SPP - ${EXP^}"
  echo "########################################"
  echo -e "$LOGO"
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

#menus and functions

main() {

  while true; do
  
    expansion_menu
 
    service_menu
  done
}
expansion_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Choose Expansion:"
    echo

    for i in "${!ALLOWED_EXPANSIONS[@]}"; do
      EXP="${ALLOWED_EXPANSIONS[$i]}"
      CTID="${GAME_CTIDS[$EXP]:-}"
      STATUS=$([[ -n "$CTID" ]] && echo "[Installed - CTID $CTID]" || echo "[Not Installed]")
      echo "$((i+1)) - ${EXP^}"
      echo "       $STATUS"
      echo
    done

    [[ -n "${EXPANSION:-}" ]] && echo "S - Shared Services"
    echo "0 - Exit"
    echo

    read -p "Selection: " SEL
    SEL="${SEL:-}"

    [[ "$SEL" == "0" ]] && exit 0

    if [[ "$SEL" =~ ^[Ss]$ ]]; then
      shared_services_menu
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
    echo "Shared Services"
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
pct exec "$GAME_CTID" -- systemctl stop mangosd || true

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
pct exec "$GAME_CTID" -- systemctl start mangosd
}

shared_config_menu() {
  echo
  echo "Configuration"
  echo
  echo "1 - Apply Server Confs"
  echo "2 - Fix Realmlist"
  echo "3 - Autostart services creation"
  echo "4 - RealmD Install"
  echo "5 - spp configs"
  echo "6 - Fix mariadb configs"
  echo "0 - Back"

  read -p "Selection: " C

  case "$C" in
    1) update_db_conf ;;
    2) fix_realm_entry ;;
    3) service_create ;;
	4) deploy_realmd ;;
	5) deploy_spp_configs ;;
	6) fix_mariadb_bind ;;
  esac
}
update_db_conf() {
  derive_db_names || return 1

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

  # realmd.conf — master only, once
  local MASTER_INSTALL_DIR
  case "$MASTER_EXPANSION" in
    classic) MASTER_INSTALL_DIR="/srv/mangos-classic" ;;
    tbc)     MASTER_INSTALL_DIR="/srv/mangos-tbc" ;;
    wotlk)   MASTER_INSTALL_DIR="/srv/mangos-wotlk" ;;
  esac

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

  # mangosd.conf — loop all installed expansions
  for EXP in "${!GAME_CTIDS[@]}"; do
    GAME_CTID="${GAME_CTIDS[$EXP]}"
    EXPANSION="$EXP"
    derive_db_names || continue

    pct exec "$GAME_CTID" -- bash -c "
      sed -i \
      -e 's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
      -e 's|^WorldDatabaseInfo *=.*|WorldDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
      -e 's|^CharacterDatabaseInfo *=.*|CharacterDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
      -e 's|^LogsDatabaseInfo *=.*|LogsDatabaseInfo      = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' \
      ${INSTALL_DIR}/etc/mangosd.conf
    "
    echo "${EXP} mangosd.conf updated."
  done
}
service_create() {
  if [[ -z "${EXPANSION:-}" ]]; then
    echo "Select expansion:"
    select EXP in classic tbc wotlk; do
      [[ -n "$EXP" ]] && EXPANSION="$EXP" && break
    done
  fi
  derive_db_names

  # realmd service only written/reloaded on master expansion
  if is_master; then
    pct exec "$LOGIN_CTID" -- bash -c "
cat > /etc/systemd/system/realmd.service <<EOF
[Unit]
Description=CMaNGOS Realmd
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
Description=CMaNGOS World Server ($EXPANSION)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/bin
ExecStart=$INSTALL_DIR/bin/mangosd -c $INSTALL_DIR/etc/mangosd.conf
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
"
  pct exec "$GAME_CTID" -- systemctl daemon-reload

  apply_autostart_setting
}
fix_realm_entry() {
  if [[ -z "${EXPANSION:-}" ]]; then
    echo "Select expansion:"
    select EXP in classic tbc wotlk; do
      [[ -n "$EXP" ]] && EXPANSION="$EXP" && break
    done
  fi

  derive_db_names || return 1

  LOGIN_IP=$(pct exec "$LOGIN_CTID" -- hostname -I | awk '{print $1}')

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'

    mariadb -u root ${REALM_DB_NAME} -e \"
      DELETE FROM realmlist WHERE id=${REALM_ID};
      DELETE FROM realmlist WHERE name='SPP-${EXPANSION^}';

      INSERT INTO realmlist
        (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel)
      VALUES
        (${REALM_ID}, 'SPP-${EXPANSION^}', '${LOGIN_IP}', 8085, 1, 0, 1, 0);
    \"
  "

  echo "Realm entry updated for ${EXPANSION^} (ID: ${REALM_ID}) in ${REALM_DB_NAME}."
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

if [[ -z "${EXPANSION:-}" ]]; then
  echo "Select expansion:"
  select EXP in classic tbc wotlk; do
    [[ -n "$EXP" ]] && EXPANSION="$EXP" && break
  done
fi

case "$EXPANSION" in
  classic) INSTALL_DIR="/srv/mangos-classic" ;;
  tbc)     INSTALL_DIR="/srv/mangos-tbc" ;;
  wotlk)   INSTALL_DIR="/srv/mangos-wotlk" ;;
esac

derive_db_names || return 1

pct exec "$GAME_CTID" -- bash -c "
set -e
cd /opt
rm -rf spp-settings
git clone --depth 1 --filter=blob:none --sparse https://github.com/japtenks/spp-cmangos-prox.git spp-settings
cd spp-settings
git sparse-checkout set Settings/${MAP_KEY}

CONF_DIR=\"Settings/${MAP_KEY}\"
cp -f \$CONF_DIR/*.conf $INSTALL_DIR/etc/
"
}
deploy_realmd() {
  deploy_spp_configs || return 1

  case "$EXPANSION" in
    classic) INSTALL_DIR="/srv/mangos-classic" ;;
    tbc)     INSTALL_DIR="/srv/mangos-tbc" ;;
    wotlk)   INSTALL_DIR="/srv/mangos-wotlk" ;;
  esac

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
}

shared_website_menu() {
  echo
  echo "Website"
  echo
  echo "1 - Install Website"
  echo "2 - Update Website"
  echo "3 - Align php for website db"
  echo
  echo "0 - Back"

  read -p "Selection: " W

  case "$W" in
    1) install_website ;;
    2) update_website ;;
	3) web_config ;;
  esac
}
install_website() {
  derive_db_names || return 1

  if ! is_master; then
    echo "Website is pinned to master expansion: ${MASTER_EXPANSION}."
    echo "To change the active world shown on the website, use 'Website' -> 'Switch Active World'."
    read -p "Press Enter to continue..."
    return 0
  fi

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

  echo
  echo "Installing Website (master: ${MASTER_EXPANSION})..."
  echo

  pct exec "$WEB_CTID" -- bash -c "
    set -e
    rm -rf /var/www/html
    git clone --depth 1 https://github.com/japtenks/SPP-Armory-Website.git /var/www/html
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
  echo
  read -p "Press Enter to continue..."
}

install_website_db() {
  derive_db_names || return 1

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
    if [ ! -d /opt/SPP-Armory-Website ]; then
      git clone https://github.com/japtenks/SPP-Armory-Website /opt/SPP-Armory-Website
    fi
    cd /opt/SPP-Armory-Website
    git fetch origin
    git reset --hard origin/HEAD

    rsync -a --delete \
      --exclude 'config/config-protected.php' \
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
  derive_db_names || return 1

  local DB_IP
  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')
    local WEB_IP
  WEB_IP=$(pct exec "$WEB_CTID" -- hostname -I | awk '{print $1}')

  pct exec "$WEB_CTID" -- bash -c "
    FILE=/var/www/html/config/config-protected.php
    sed -i \"s|'host' => '.*'|'host' => '${DB_IP}'|\"       \$FILE
    sed -i \"s|'port' => .*,|'port' => 3306,|\"             \$FILE
    sed -i \"s|'user' => '.*'|'user' => '${DB_LAN_USER}'|\" \$FILE
    sed -i \"s|'pass' => '.*'|'pass' => '${DB_LAN_PASS}'|\" \$FILE
  "

  echo "Web config updated — Bookmark website at http://${WEB_IP}"
  read -p "Press Enter to continue..."
}

service_menu() {
  auto_detect_stack
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"


ensure_shared_stack || return
ensure_game_container || return

  while true; do
    clear
    print_banner
    print_version

    echo
    echo "1 - Stack Control"
    echo "2 - Maintenance"
    echo
    echo "4 - Remote Console"
    echo "5 - Live World Log"
    echo
    echo "6 - Autostart Status: ($ASV)"
	echo "7 - Server Info"
    echo "0 - Expansion Select"
    echo

    read -p "Selection: " MAIN

    case "$MAIN" in
      1) stack_control_menu ;;
      2) maintenance_menu ;;
      4) connect_ra ;;
      5) live_logs ;;
      6) toggle_autostart ;;
	  7) server_info_menu ;;
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
    pct exec "$GAME_CTID" -- systemctl start mangosd
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
    # Show current mode if we can detect it
    echo "1 - Apply Stock Settings"
    echo "2 - Apply Sagrids Settings"
    echo "3 - Apply Custom Settings (prompted)"
    echo "0 - Back"
    echo
    read -p "Selection: " CSEL
    case "$CSEL" in
      1) apply_config "stock" ;;
      2) apply_config "sagrids" ;;
      3) apply_config_prompted ;;
      0) return ;;
    esac
  done
}
apply_config() {
  local MODE=$1
  local CONF_DIR="/srv/mangos-${EXPANSION}/etc"
  local CONF="$CONF_DIR/aiplayerbot.conf"

  # Check server is stopped
  if pct exec "$GAME_CTID" -- systemctl is-active mangosd &>/dev/null; then
    echo "ERROR: Server is still running. Stop the server before changing settings."
    read -p "Press Enter to continue..."
    return
  fi

  # Confirm
  echo
  echo "Applying $MODE settings to aiplayerbot.conf"
  read -p "Confirm? (YES): " CONFIRM
  [[ "$CONFIRM" != "YES" ]] && return

  # Backup - find next available backup number
  local BKUP_NUM=1
  while pct exec "$GAME_CTID" -- test -f "${CONF}.bkup${BKUP_NUM}"; do
    ((BKUP_NUM++))
  done
  pct exec "$GAME_CTID" -- cp "$CONF" "${CONF}.bkup${BKUP_NUM}"
  echo "Backup saved as aiplayerbot.conf.bkup${BKUP_NUM}"

  if [[ "$MODE" == "stock" ]]; then
    pct exec "$GAME_CTID" -- bash -c "
      sed -i 's/^AiPlayerbot\.DisableBotOptimizations.*/AiPlayerbot.DisableBotOptimizations = 0/' $CONF
      sed -i 's/^AiPlayerbot\.DisableActivityPriorities.*/AiPlayerbot.DisableActivityPriorities = 0/' $CONF
      sed -i 's/^AiPlayerbot\.DisableRandomLevels.*/AiPlayerbot.DisableRandomLevels = 0/' $CONF
      sed -i 's/^AiPlayerbot\.XPRate.*/AiPlayerbot.XPRate = 1/' $CONF
      sed -i 's/^AiPlayerbot\.RandomGearMaxLevel.*/AiPlayerbot.RandomGearMaxLevel = 500/' $CONF
      sed -i 's/^AiPlayerbot\.RandomGearMaxDiff.*/AiPlayerbot.RandomGearMaxDiff = 9/' $CONF
      sed -i 's/^AiPlayerbot\.RandomGearUpgradeEnabled.*/AiPlayerbot.RandomGearUpgradeEnabled = 0/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotMaps.*/AiPlayerbot.RandomBotMaps = 0,1,530,571/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotTeleportTeleportMinInterval.*/AiPlayerbot.RandomBotTeleportTeleportMinInterval = 7200/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotRpgChance.*/AiPlayerbot.RandomBotRpgChance = 0.20/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotGuildCount.*/AiPlayerbot.RandomBotGuildCount = 20/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotArenaTeamCount.*/AiPlayerbot.RandomBotArenaTeamCount = 20/' $CONF
      sed -i 's/^AiPlayerbot\.DeleteRandomBotArenaTeams.*/AiPlayerbot.DeleteRandomBotArenaTeams = 0/' $CONF
      sed -i 's/^AiPlayerbot\.EnableGreet.*/AiPlayerbot.EnableGreet = 1/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotAccountCount.*/AiPlayerbot.RandomBotAccountCount = 200/' $CONF
    "

  elif [[ "$MODE" == "custom" ]]; then
    pct exec "$GAME_CTID" -- bash -c "
      sed -i 's/^AiPlayerbot\.DisableBotOptimizations.*/AiPlayerbot.DisableBotOptimizations = 1/' $CONF
      sed -i 's/^AiPlayerbot\.DisableActivityPriorities.*/AiPlayerbot.DisableActivityPriorities = 1/' $CONF
      sed -i 's/^AiPlayerbot\.DisableRandomLevels.*/AiPlayerbot.DisableRandomLevels = 1/' $CONF
      sed -i 's/^AiPlayerbot\.XPRate.*/AiPlayerbot.XPRate = 4/' $CONF
      sed -i 's/^AiPlayerbot\.RandomGearMaxLevel.*/AiPlayerbot.RandomGearMaxLevel = 50/' $CONF
      sed -i 's/^AiPlayerbot\.RandomGearMaxDiff.*/AiPlayerbot.RandomGearMaxDiff = 20/' $CONF
      sed -i 's/^AiPlayerbot\.RandomGearUpgradeEnabled.*/AiPlayerbot.RandomGearUpgradeEnabled = 1/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotMaps.*/AiPlayerbot.RandomBotMaps = 0,1/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotTeleportTeleportMinInterval.*/AiPlayerbot.RandomBotTeleportTeleportMinInterval = 86400/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotRpgChance.*/AiPlayerbot.RandomBotRpgChance = 0.5/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotGuildCount.*/AiPlayerbot.RandomBotGuildCount = 0/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotArenaTeamCount.*/AiPlayerbot.RandomBotArenaTeamCount = 0/' $CONF
      sed -i 's/^AiPlayerbot\.DeleteRandomBotArenaTeams.*/AiPlayerbot.DeleteRandomBotArenaTeams = 1/' $CONF
      sed -i 's/^AiPlayerbot\.EnableGreet.*/AiPlayerbot.EnableGreet = 0/' $CONF
      sed -i 's/^AiPlayerbot\.RandomBotAccountCount.*/AiPlayerbot.RandomBotAccountCount = 500/' $CONF
    "
  fi

  echo "Done. Settings applied successfully."
  echo
  read -p "Start server now? (Y/N): " START
  if [[ "$START" == "Y" ]]; then
    pct exec "$GAME_CTID" -- systemctl start mangosd
    echo "Server started."
  fi
  read -p "Press Enter to continue..."
}

apply_config_prompted() {
  local CONF_DIR="/srv/mangos-${EXPANSION}/etc"
  local CONF="$CONF_DIR/aiplayerbot.conf"

  # Check server is stopped
  if pct exec "$GAME_CTID" -- systemctl is-active mangosd &>/dev/null; then
    echo "ERROR: Server is still running. Stop the server before changing settings."
    read -p "Press Enter to continue..."
    return
  fi

  echo
  echo "Custom Config - Prompted"
  echo "For each setting enter S (Stock) or C (Custom/Sagrids)"
  echo
  echo "Stock values shown first, Sagrids values shown second."
  echo

  # Collect all choices first
  declare -A CHOICES

  prompt_setting() {
    local KEY=$1
    local STOCK=$2
    local CUSTOM=$3
    local DESC=$4
    while true; do
      echo "  $DESC"
      echo "    S = $STOCK"
      echo "    C = $CUSTOM"
      read -p "  Choice [S/C]: " CHOICE
      CHOICE="${CHOICE^^}"
      if [[ "$CHOICE" == "S" || "$CHOICE" == "C" ]]; then
        CHOICES[$KEY]=$CHOICE
        break
      fi
      echo "  Invalid input, enter S or C"
    done
    echo
  }

  prompt_setting "DisableBotOptimizations"          "0"         "1"      "DisableBotOptimizations    (0=off, 1=all bots always active)"
  prompt_setting "DisableActivityPriorities"        "0"         "1"      "DisableActivityPriorities  (0=off, 1=ignore activity priorities)"
  prompt_setting "DisableRandomLevels"              "0"         "1"      "DisableRandomLevels        (0=random levels, 1=bots level naturally)"
  prompt_setting "XPRate"                           "1"         "4"      "XPRate                     (1=normal, 4=4x XP for bots)"
  prompt_setting "RandomGearMaxLevel"               "500"       "50"     "RandomGearMaxLevel          (500=no cap, 50=progression cap)"
  prompt_setting "RandomGearMaxDiff"                "9"         "20"     "RandomGearMaxDiff           (9=strict, 20=looser gear diff)"
  prompt_setting "RandomGearUpgradeEnabled"         "0"         "1"      "RandomGearUpgradeEnabled    (0=off, 1=bots upgrade gear over time)"
  prompt_setting "RandomBotMaps"                    "0,1,530,571" "0,1"  "RandomBotMaps               (all maps vs Classic only)"
  prompt_setting "RandomBotTeleportMinInterval"     "7200"      "86400"  "TeleportMinInterval         (7200=2hrs, 86400=24hrs)"
  prompt_setting "RandomBotRpgChance"               "0.20"      "0.5"    "RandomBotRpgChance          (0.20=less RPG, 0.5=more RPG)"
  prompt_setting "RandomBotGuildCount"              "20"        "0"      "RandomBotGuildCount         (20=bot guilds, 0=none)"
  prompt_setting "RandomBotArenaTeamCount"          "20"        "0"      "RandomBotArenaTeamCount     (20=arena teams, 0=none)"
  prompt_setting "DeleteRandomBotArenaTeams"        "0"         "1"      "DeleteRandomBotArenaTeams   (0=keep, 1=delete)"
  prompt_setting "EnableGreet"                      "1"         "0"      "EnableGreet                 (1=bots greet players, 0=silent)"
  prompt_setting "RandomBotAccountCount"            "200"       "500"    "RandomBotAccountCount       (200=stock, 500=sagrids)"

  # Summary
  echo
  echo "========================================"
  echo " Summary of your choices:"
  echo "========================================"
  for KEY in "${!CHOICES[@]}"; do
    echo "  $KEY = ${CHOICES[$KEY]}"
  done
  echo
  read -p "Apply these settings? (YES): " CONFIRM
  [[ "$CONFIRM" != "YES" ]] && return

  # Backup
  local BKUP_NUM=1
  while pct exec "$GAME_CTID" -- test -f "${CONF}.bkup${BKUP_NUM}"; do
    ((BKUP_NUM++))
  done
  pct exec "$GAME_CTID" -- cp "$CONF" "${CONF}.bkup${BKUP_NUM}"
  echo "Backup saved as aiplayerbot.conf.bkup${BKUP_NUM}"

  # Build sed values based on choices
  get_value() {
    local KEY=$1
    local STOCK=$2
    local CUSTOM=$3
    if [[ "${CHOICES[$KEY]}" == "S" ]]; then
      echo "$STOCK"
    else
      echo "$CUSTOM"
    fi
  }

  pct exec "$GAME_CTID" -- bash -c "
    sed -i 's/^AiPlayerbot\.DisableBotOptimizations.*/AiPlayerbot.DisableBotOptimizations = $(get_value DisableBotOptimizations 0 1)/' $CONF
    sed -i 's/^AiPlayerbot\.DisableActivityPriorities.*/AiPlayerbot.DisableActivityPriorities = $(get_value DisableActivityPriorities 0 1)/' $CONF
    sed -i 's/^AiPlayerbot\.DisableRandomLevels.*/AiPlayerbot.DisableRandomLevels = $(get_value DisableRandomLevels 0 1)/' $CONF
    sed -i 's/^AiPlayerbot\.XPRate.*/AiPlayerbot.XPRate = $(get_value XPRate 1 4)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomGearMaxLevel.*/AiPlayerbot.RandomGearMaxLevel = $(get_value RandomGearMaxLevel 500 50)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomGearMaxDiff.*/AiPlayerbot.RandomGearMaxDiff = $(get_value RandomGearMaxDiff 9 20)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomGearUpgradeEnabled.*/AiPlayerbot.RandomGearUpgradeEnabled = $(get_value RandomGearUpgradeEnabled 0 1)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomBotMaps.*/AiPlayerbot.RandomBotMaps = $(get_value RandomBotMaps 0,1,530,571 0,1)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomBotTeleportTeleportMinInterval.*/AiPlayerbot.RandomBotTeleportTeleportMinInterval = $(get_value RandomBotTeleportMinInterval 7200 86400)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomBotRpgChance.*/AiPlayerbot.RandomBotRpgChance = $(get_value RandomBotRpgChance 0.20 0.5)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomBotGuildCount.*/AiPlayerbot.RandomBotGuildCount = $(get_value RandomBotGuildCount 20 0)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomBotArenaTeamCount.*/AiPlayerbot.RandomBotArenaTeamCount = $(get_value RandomBotArenaTeamCount 20 0)/' $CONF
    sed -i 's/^AiPlayerbot\.DeleteRandomBotArenaTeams.*/AiPlayerbot.DeleteRandomBotArenaTeams = $(get_value DeleteRandomBotArenaTeams 0 1)/' $CONF
    sed -i 's/^AiPlayerbot\.EnableGreet.*/AiPlayerbot.EnableGreet = $(get_value EnableGreet 1 0)/' $CONF
    sed -i 's/^AiPlayerbot\.RandomBotAccountCount.*/AiPlayerbot.RandomBotAccountCount = $(get_value RandomBotAccountCount 200 500)/' $CONF
  "

  echo
  echo "Done. Settings applied successfully."
  echo
  read -p "Start server now? (Y/N): " START
  if [[ "$START" == "Y" ]]; then
    pct exec "$GAME_CTID" -- systemctl start mangosd
    echo "Server started."
  fi
  read -p "Press Enter to continue..."
}
core_menu() {
  while true; do
    #clear
    print_banner

    echo
    echo "Core Maintenance"
    echo
    echo "1 - Clean Rebuild"
    echo "2 - Incremental Update"
    echo "0 - Back"
    echo

    read -p "Selection: " CORE

    case "$CORE" in
      1)
        read -p "Confirm rebuild? (Y/N): " CONFIRM
        if [[ "$CONFIRM" == "Y" ]]; then
          pct exec "$GAME_CTID" -- rm -rf /opt/source
          comp_server
        fi
        ;;
      2)
        read -p "Confirm update? (YES): " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && update_core
        ;;
      0) return ;;
    esac
  done
}
comp_server() {
  
case "$EXPANSION" in
  classic)
    REPO="https://github.com/celguar/mangos-classic.git"
    INSTALL_DIR="/srv/mangos-classic"
    ;;
  tbc)
    REPO="https://github.com/celguar/mangos-tbc.git"
    INSTALL_DIR="/srv/mangos-tbc"
    ;;
  wotlk)
    REPO="https://github.com/celguar/mangos-wotlk.git"
    INSTALL_DIR="/srv/mangos-wotlk"
    ;;
esac

pct exec "$GAME_CTID" -- bash -c "
set -e

cd /opt

if [[ -d source ]]; then
  echo 'Updating existing core...'
  cd source
  git fetch
  git checkout ike3-bots
  git pull

cd src/modules/playerbot
git fetch
git checkout master
git pull
else
  echo 'Cloning fresh core...'
  git clone $REPO source
  cd source
  git checkout ike3-bots
  sed -i 's|davidonete/cmangos-modules|japtenks/cmangos-modules|g' /opt/source/CMakeLists.txt
  mkdir -p src/modules
  cd src/modules
  git clone https://github.com/cmangos/playerbots.git playerbot
fi
"
pct exec "$GAME_CTID" -- bash -c "
cd /opt/source &&
mkdir -p build &&
cd build &&
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
  -DBUILD_MODULE_ACHIEVEMENTS=ON \
  -DBUILD_MODULE_IMMERSIVE=ON \
  -DBUILD_MODULE_HARDCORE=ON \
  -DBUILD_MODULE_TRANSMOG=ON \
  -DBUILD_MODULE_DUALSPEC=ON \
  -DBUILD_MODULE_BOOST=ON \
  -DBUILD_MODULE_CUSTOM20=ON \
  -DBUILD_MODULE_BALANCING=ON \
  -DBUILD_MODULE_BARBER=ON \
  -DBUILD_MODULE_TRAININGDUMMIES=ON \
  -DBUILD_MODULE_VOICEOVER=ON &&
make -j\$(nproc) &&
make install &&
mkdir -p /var/log/mangos/
"

update_core_metadata

#deploy_realmd
update_db_conf
}

update_core() {

OLD_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)
OLD_BOT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse HEAD)


pct exec "$GAME_CTID" -- bash -c "
set -e
cd /opt/source
git fetch
git checkout ike3-bots
git pull
sed -i 's|davidonete/cmangos-modules|japtenks/cmangos-modules|g' /opt/source/CMakeLists.txt
cd src/modules/playerbot
git fetch
git pull
"

NEW_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)
NEW_BOT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse HEAD)

if [[ "$OLD_CORE" != "$NEW_CORE" || "$OLD_BOT" != "$NEW_BOT" ]]; then
  # Stop server before installing
  pct exec "$GAME_CTID" -- bash -c "systemctl stop mangos || true"
  
  pct exec "$GAME_CTID" -- bash -c "
  cd /opt/source/build
  make -j\$(nproc)
  make install
  "
  
  # Start server again after install
  pct exec "$GAME_CTID" -- bash -c "systemctl start mangos || true"
fi

update_core_metadata
}
update_core_metadata() {
CORE_BRANCH=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse --abbrev-ref HEAD)
CORE_COMMIT=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse --short HEAD)
BOT_BRANCH=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse --abbrev-ref HEAD)
BOT_COMMIT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse --short HEAD)
BUILD_DATE=$(date +%F_%H:%M)

KEY=$(echo "$EXPANSION" | tr '[:lower:]' '[:upper:]')
EXPECTED_CORE="${VERSION_MAP[$EXPANSION:CORE]}"

write_version "${EXPANSION}_core_version.spp" \
"${EXPECTED_CORE}|${CORE_BRANCH}|${CORE_COMMIT}|${BOT_BRANCH}|${BOT_COMMIT}|${BUILD_DATE}"
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
      0) return ;;
    esac
  done
}

install_db() {
  derive_db_names || return 1
  echo "Installing full DB (including realm)..."
  install_world
  install_char
  install_armory
  install_logs
  install_realm
  create_lan_db_user
  fix_realm_entry
  echo "DB install complete."
}
# Non-master expansions skip realm DB install
install_db_no_realm() {
  derive_db_names || return 1
  echo "Installing expansion DB (world/chars/logs only)..."
  install_world
  install_char
  install_armory
  install_logs
  # Grant LAN user access to new DBs - realm DB already exists from master
  create_lan_db_user
  fix_realm_entry
  echo "DB install complete."
}

install_world() {
  derive_db_names || return 1
  echo "Installing world DB..."
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
install_realm() {
  derive_db_names || return 1

  # Pin master on first realm install
  pin_master_expansion

  echo "Installing realm DB..."

  if pct exec "$DB_CTID" -- bash -c "
    set -euo pipefail
    export MYSQL_PWD='${DB_ROOT_PASS}'

    BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"
    REALM_DB=\"${REALM_DB_NAME}\"

    mariadb -u root < \"\$BASE/drop_realmd.sql\"
    mariadb -u root \"\$REALM_DB\" < \"\$BASE/realmd.sql\"
    mariadb -u root \"\$REALM_DB\" < \"\$BASE/realmlist.sql\"

    for f in \"\$BASE/realmd\"/*.sql; do
      [ -f \"\$f\" ] && mariadb -u root \"\$REALM_DB\" < \"\$f\"
    done

    for dir in \$(ls -1 \"\$BASE/updates/realmd\" | sort -n); do
      for f in \"\$BASE/updates/realmd/\$dir\"/*.sql; do
        [ -f \"\$f\" ] && mariadb -u root \"\$REALM_DB\" < \"\$f\"
      done
    done
  "; then
    echo "Realm DB installed successfully."
  else
    echo "Realm DB install FAILED."
    return 1
  fi

  write_version "${MASTER_EXPANSION}_realm_version.spp" "${VERSION_MAP[$EXPANSION:REALM]}"
  read -p "Press Enter to return..." _
}
install_char() {
  derive_db_names || return 1

    echo "Installing world DB..."
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

install_realm() {
  derive_db_names || return 1
  pin_master_expansion
  echo "Installing realm DB..."

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

  write_version "${MASTER_EXPANSION}_realm_version.spp" "${VERSION_MAP[$EXPANSION:REALM]}"
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
  pct exec "$GAME_CTID" -- systemctl stop mangosd 2>/dev/null || true

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

  if is_master; then
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

  # Only drop realm DB if we are the master (it's shared)
  if is_master; then
    pct exec "$DB_CTID" -- bash -c "
      export MYSQL_PWD='${DB_ROOT_PASS}'
      mariadb -u root -e \"DROP DATABASE IF EXISTS ${REALM_DB_NAME};\"
    "
    pin_master_expansion
  fi

  comp_server

  if is_master; then
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
  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt
    rm -rf spp-settings
    git clone --depth 1 --filter=blob:none --sparse \
      https://github.com/japtenks/spp-cmangos-prox.git spp-settings
    cd spp-settings
    git sparse-checkout set Settings/${MAP_KEY}
  "
}


stack_control_menu() {
  while true; do
    #clear
    print_banner
    stat_state
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
pct exec "$GAME_CTID" -- systemctl start mangosd

}

server_info_menu() {
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
    echo "4 - Change Server Address"
    echo "5 - Change Realm Name"

    echo "7 - Crash Logs"
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
     
      7) view_crash_logs ;;
      0) return ;;
    esac
  done
}
edit_world_settings() {
  pct exec "$GAME_CTID" -- nano /srv/mangos-$EXPANSION/etc/mangosd.conf
}
edit_bot_settings() {
  pct exec "$GAME_CTID" -- nano /srv/mangos-$EXPANSION/etc/aiplayerbot.conf
}
edit_realmd_settings() {
  pct exec "$LOGIN_CTID" -- nano /srv/mangos-$EXPANSION/etc/realmd.conf
}
change_server_address() {
  read -p "Enter new public IP: " NEWIP

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root ${REALM_DB_NAME} -e \"
      UPDATE realmlist SET address='${NEWIP}' WHERE id=1;
    \"
  "

  echo "Realm address updated."
  read -p "Press Enter..."
}
change_realm_name() {
  read -p "Enter new realm name: " NEWNAME

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root ${REALM_DB_NAME} -e \"
      UPDATE realmlist SET name='${NEWNAME}' WHERE id=1;
    \"
  "

  echo "Realm name updated."
  read -p "Press Enter..."
}
view_crash_logs() {
  pct exec "$GAME_CTID" -- bash -c "
    ls -lh /srv/mangos-$EXPANSION | grep core || echo 'No crash logs.'
  "
  read -p "Press Enter..."
}



echo "DEBUG: reaching main" >&2

#program starts here
main
