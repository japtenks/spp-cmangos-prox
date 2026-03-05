#!/bin/bash
set -euo pipefail
DRY_RUN=0
# -------------------------
# First Run Bootstrap
# -------------------------
CONFIG_FILE="./config.env"
declare -A GAME_CTIDS

auto_detect_stack() {
  DB_CTID=$(pct list | awk '$3=="spp-db" {print $1}')
  WEB_CTID=$(pct list | awk '$3=="spp-web" {print $1}')
  LOGIN_CTID=$(pct list | awk '$3=="spp-login" {print $1}')

  for EXP in classic tbc wotlk; do
    CT=$(pct list | awk -v name="spp-$EXP" '$3==name {print $1}')
    if [[ -n "$CT" ]]; then
      KEY=$(echo "$EXP" | tr '[:lower:]' '[:upper:]')
      GAME_CTIDS[$EXP]=$CT
    fi
  done
}

if [[ ! -f $CONFIG_FILE ]]; then
  echo "Config missing. Attempting auto-detection..."

  auto_detect_stack

  if [[ -n "$DB_CTID" ]]; then
    echo "Existing containers detected. Rebuilding config..."
    DB_ROOT_PASS=""
    GAME_CORES=4
    GAME_RAM=4096
    STORAGE_CHOICE=$(pvesm status | awk '$3=="active"{print $1}' | head -n1)
  else
    echo "No stack detected. Running First Run Bootstrap."

    read -p "DB root password: " DB_ROOT_PASS
    read -p "LXC Game Cores: " GAME_CORES
    read -p "LXC Game Ram (MB): " GAME_RAM

    mapfile -t STORAGE_LIST < <(pvesm status | awk '$3=="active"{print $1}')
    select STORAGE_CHOICE in "${STORAGE_LIST[@]}"; do
      [[ -n "$STORAGE_CHOICE" ]] && break
    done
  fi

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
AUTO_START="0"   # 0 = manual, 1 = auto-enable
ASV="Off"		

DB_HOST=""
DB_PORT="3306"
DB_ROOT_PASS="$DB_ROOT_PASS"
ADMIN_USER=""
ADMIN_PASS=""

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

EOF

  # ---- Append detected CTIDs if they exist ----
  for EXP in classic tbc wotlk; do
    KEY=$(echo "$EXP" | tr '[:lower:]' '[:upper:]')
    GAME_VAL="${GAME_CTIDS[$EXP]:-}"

    if [[ -n "$GAME_VAL" && -n "$DB_CTID" ]]; then
      cat <<EOF >> "$CONFIG_FILE"
${KEY}_DB_CTID=$DB_CTID
${KEY}_WEB_CTID=$WEB_CTID
${KEY}_LOGIN_CTID=$LOGIN_CTID
${KEY}_GAME_CTID=$GAME_VAL
EOF
    fi
  done

  echo "config.env created."
fi

source "$CONFIG_FILE"
: ${INSTALLED_EXPANSIONS:=()}
EXPANSION=""
declare -A VERSION_MAP

for EXP in classic tbc wotlk; do
  KEY=$(echo "$EXP" | tr '[:lower:]' '[:upper:]')

  for TYPE in WORLD CORE REALM CHARS LOGS MAPS WEBSITE; do
    VAR="${KEY}_${TYPE}_VERSION"
    VERSION_MAP["$EXP:$TYPE"]="${!VAR:-0}"
  done
done

get_storage() {
  echo "$DEFAULT_STORAGE"
}

create_container() {
  local NAME=$1
  local ROLE_TYPE=$2
  local CTID=$3
  local START_ORDER=$4

  if pct list | awk 'NR>1 {print $1}' | grep -q "^$CTID$"; then
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

  CMD=(
    pct create "$CTID" "$TEMPLATE"
    --hostname "$NAME"
    --cores "$CORES"
    --memory "$RAM"
    --rootfs "${STORAGE}:${DISK}"
    --net0 name=eth0,bridge=vmbr0,ip=dhcp
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
        wget p7zip-full

      pct exec "$CTID" -- systemctl enable apache2

      WEB_CTID="$CTID"
      install_website
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
}

ensure_web_template() {

  WEB_TEMPLATE="debian-11-standard_11.7-1_amd64.tar.zst"
  STORAGE="local"
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

  WEB_TEMPLATE_FULL="${STORAGE}:vztmpl/${WEB_TEMPLATE}"
}

derive_db_names() {
  case "$EXPANSION" in
    classic)
      DB_KEY="classic"
      MAP_KEY="vanilla"
      ;;
    tbc)
      DB_KEY="tbc"
      MAP_KEY="tbc"
      ;;
    wotlk)
      DB_KEY="wotlk"
      MAP_KEY="wotlk"
      ;;
    *)
      echo "Unknown expansion"
      return 1
      ;;
  esac

  WORLD_DB="${DB_KEY}mangos"
  CHAR_DB_NAME="${DB_KEY}characters"
  REALM_DB_NAME="${DB_KEY}realmd"
  LOG_DB_NAME="${DB_KEY}logs"
  
  case "$EXPANSION" in
  classic) INSTALL_DIR="/srv/mangos-classic" ;;
  tbc)     INSTALL_DIR="/srv/mangos-tbc" ;;
  wotlk)   INSTALL_DIR="/srv/mangos-wotlk" ;;
  *) echo "Unknown expansion: $EXPANSION"; return 1 ;;
esac
case "$EXPANSION" in
  classic) REALM_ID=1 ;;
  tbc)     REALM_ID=2 ;;
  wotlk)   REALM_ID=3 ;;
  *) echo "Unknown expansion: $EXPANSION"; return 1 ;;
esac
}

write_version() {
  local FILE=$1
  local VALUE=$2
  pct exec "$DB_CTID" -- bash -c "echo \"$VALUE\" > /opt/$FILE"
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

install_db() {
  derive_db_names || return 1
  echo "Installing full DB..."
  install_world
  install_realm
  install_char
  install_logs
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


install_realm() {
  derive_db_names || return 1
  echo "Installing realm DB..."

  GAME_IP=$(pct exec "$GAME_CTID" -- hostname -I | awk '{print $1}')
  REALM_NAME="SPP-${EXPANSION^}"

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

    REALM_ID=\$(mariadb -u root \"\$REALM_DB\" -N -e \"SELECT IFNULL(MAX(id),0)+1 FROM realmlist;\")

    mariadb -u root \"\$REALM_DB\" -e \"
      INSERT INTO realmlist (id,name,address,port,icon,realmflags,timezone,allowedSecurityLevel)
      VALUES (
        \$REALM_ID,
        '${REALM_NAME}',
        '${GAME_IP}',
        8085,
        1,
        0,
        1,
        0
      );
    \"
  "; then
    echo "Realm DB installed successfully."
  else
    echo "Realm DB install FAILED."
    return 1
  fi
  write_version "${EXPANSION}_realm_version.spp" "${VERSION_MAP[$EXPANSION:REALM]}"
}
 
install_logs() {
  derive_db_names || return 1

    echo "Installing world DB..."
 if pct exec "$DB_CTID" -- bash -c "

  export MYSQL_PWD='${DB_ROOT_PASS}'

  BASE=\"/opt/spp-sql/sql/${MAP_KEY}\"
  LOG_DB=\"${LOG_DB_NAME}\"

  mariadb -u root < \"\$BASE/drop_logs.sql\"
  mariadb -u root \"\$LOG_DB\" < \"\$BASE/logs.sql\"
  "; then
    echo "DB installed successfully."
  else
    echo "DB install FAILED."
    return 1
  fi
  write_version "${EXPANSION}_logs_version.spp" "${VERSION_MAP[$EXPANSION:LOGS]}"
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
}

full_install() {

  derive_db_names || return 1
  
  echo "Stopping services..."
  pct exec "$GAME_CTID" -- systemctl stop mangosd 2>/dev/null || true
  pct exec "$LOGIN_CTID" -- systemctl stop realmd 2>/dev/null || true

  echo "Removing old install directory..."
  pct exec "$GAME_CTID" -- rm -rf "$INSTALL_DIR"

  echo "Removing old build + source..."
  pct exec "$GAME_CTID" -- rm -rf /opt/source /opt/spp-settings

  echo "Removing version trackers..."
  rm -f "${EXPANSION}_core_version.spp"
  rm -f "${EXPANSION}_world_version.spp"
  rm -f "${EXPANSION}_logs_version.spp"

  echo "Dropping databases..."
  pct exec "$DB_CTID" -- bash -c "
  export MYSQL_PWD='${DB_ROOT_PASS}'
  mariadb -u root -e \"DROP DATABASE IF EXISTS ${WORLD_DB};\"
  mariadb -u root -e \"DROP DATABASE IF EXISTS ${CHAR_DB_NAME};\"
  mariadb -u root -e \"DROP DATABASE IF EXISTS ${REALM_DB_NAME};\"
  mariadb -u root -e \"DROP DATABASE IF EXISTS ${LOG_DB_NAME};\"
  "
  
  comp_server
  install_db
  update_maps
  service_create
  
}

update_maps() {
  derive_db_names || return 1
    URL="https://github.com/celguar/spp-classics-cmangos/releases/download/v2.0/${MAP_KEY}.7z"

  pct exec "$GAME_CTID" -- bash -c "
    set -euo pipefail
INSTALL_DIR="/srv/mangos-${EXPANSION}"

cd "$INSTALL_DIR"
mkdir -p data
cd data

    echo 'Downloading map package...'
    wget -c --show-progress --no-check-certificate \"$URL\" -O ${EXPANSION}.7z

    if [[ ! -f ${EXPANSION}.7z ]]; then
      echo 'Download failed.'
      exit 1
    fi

    echo 'Extracting...'
    7z x -y ${EXPANSION}.7z >/dev/null
    rm ${EXPANSION}.7z

    echo 'Maps ready.'
  "
MAP_EXPECTED="${VERSION_MAP[$EXPANSION:MAPS]}"
INSTALL_DATE=$(date +%F_%H:%M)

write_version "${EXPANSION}_maps_version.spp" \
"${MAP_EXPECTED}|${INSTALL_DATE}"
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

cd src/modules/PlayerBots
git fetch
git checkout master
git pull
else
  echo 'Cloning fresh core...'
  git clone $REPO source
  cd source
  git checkout ike3-bots

  mkdir -p src/modules
  cd src/modules
  git clone https://github.com/cmangos/playerbots.git PlayerBots
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
  -DBUILD_MODULE_BARBER=ON \
  -DBUILD_MODULE_TRAININGDUMMIES=ON \
  -DBUILD_MODULE_VOICEOVER=ON &&
make -j\$(nproc) &&
make install &&
mkdir -p /var/log/mangos/
"

CORE_BRANCH=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse --abbrev-ref HEAD)
CORE_COMMIT=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse --short HEAD)
BUILD_DATE=$(date +%F_%H:%M)
BOT_BRANCH=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse --abbrev-ref HEAD)
BOT_COMMIT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse --short HEAD)

KEY=$(echo "$EXPANSION" | tr '[:lower:]' '[:upper:]')
EXPECTED_CORE="${VERSION_MAP[$EXPANSION:CORE]}"
write_version "${EXPANSION}_core_version.spp" \
"${EXPECTED_CORE}|${CORE_BRANCH}|${CORE_COMMIT}|${BOT_BRANCH}|${BOT_COMMIT}|${BUILD_DATE}"

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
# ----------------------------
# Deploy realmd to Login LXC
# ----------------------------

# Create dirs on login container
pct exec "$LOGIN_CTID" -- mkdir -p "$INSTALL_DIR/bin"
pct exec "$LOGIN_CTID" -- mkdir -p "$INSTALL_DIR/etc"

# Copy realmd binary + default config
if ! pct exec "$GAME_CTID" -- test -f "$INSTALL_DIR/bin/realmd"; then
  echo "ERROR: realmd binary not found in $INSTALL_DIR on game container."
  return 1
fi

# Copy realmd binary from installed core
pct exec "$GAME_CTID" -- tar -C "$INSTALL_DIR" -cf - bin/realmd | \
pct exec "$LOGIN_CTID" -- tar -C "$INSTALL_DIR" -xf -

# Copy realmd.conf from SPP repo
pct exec "$GAME_CTID" -- tar -C "/opt/spp-settings/Settings/${MAP_KEY}" -cf - realmd.conf | \
pct exec "$LOGIN_CTID" -- tar -C "$INSTALL_DIR/etc" -xf -

# Create realmd.conf if missing
pct exec "$LOGIN_CTID" -- bash -c "
cd $INSTALL_DIR/etc
if [[ ! -f realmd.conf ]]; then
  cp realmd.conf.dist realmd.conf
fi
"
update_db_conf
}



create_lan_db_user() {
  derive_db_names || return 1

  ARMORY_DB="${EXPANSION}armory"
  pct exec "$DB_CTID" -- bash -c "
  export MYSQL_PWD='${DB_ROOT_PASS}'

  mariadb -u root -e \"
  CREATE USER IF NOT EXISTS '${DB_LAN_USER}'@'${DB_LAN_HOST}' IDENTIFIED BY '${DB_LAN_PASS}';
  GRANT ALL PRIVILEGES ON ${WORLD_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${CHAR_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${REALM_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${LOG_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${ARMORY_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  FLUSH PRIVILEGES;
  \"
  "
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

start_stack() {

  # Start containers if needed
  for CT in "$DB_CTID" "$WEB_CTID" "$LOGIN_CTID" "$GAME_CTID"; do
    STATE=$(pct status "$CT" | awk '{print $2}')
    if [[ "$STATE" != "running" ]]; then
      pct start "$CT"
    fi
  done

  # Start services explicitly
  pct exec "$DB_CTID" -- systemctl start mariadb
  pct exec "$LOGIN_CTID" -- systemctl start realmd
  pct exec "$WEB_CTID" -- systemctl start apache2
  pct exec "$GAME_CTID" -- systemctl start mangosd

}

stop_world() {
  if [[ "$(pct status "$GAME_CTID" | awk '{print $2}')" != "running" ]]; then
    echo "World already stopped."
    return
  fi

  echo "Stopping World..."
  pct stop "$GAME_CTID"
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
    | |/ |/ / _ \/ __/ /__/ ,<
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
  |____/|_|   |_|    
"
      ;;
  esac

  CLEAR="\e[0m"
  clear
  echo -e "$COLOR"
  echo "########################################"
  echo "# SPP - ${EXP^}"
  echo "########################################"
  echo -e "$LOGO"
  echo -e "$CLEAR"
}

print_version() {

  CORE_RAW=$(get_live_version "/opt/${EXPANSION}_core_version.spp")
  IFS='|' read -r CORE_VER CORE_BRANCH CORE_COMMIT BOT_BRANCH BOT_COMMIT BUILD_DATE <<< "$CORE_RAW"

  WORLD_RAW=$(get_live_version "/opt/${EXPANSION}_world_version.spp")
  IFS='|' read -r WORLD_VER _ <<< "$WORLD_RAW"

  CHARS_RAW=$(get_live_version "/opt/${EXPANSION}_chars_version.spp")
  IFS='|' read -r CHARS_VER _ <<< "$CHARS_RAW"

  REALM_RAW=$(get_live_version "/opt/${EXPANSION}_realm_version.spp")
  IFS='|' read -r REALM_VER _ <<< "$REALM_RAW"

  LOGS_RAW=$(get_live_version "/opt/${EXPANSION}_logs_version.spp")
  IFS='|' read -r LOGS_VER _ <<< "$LOGS_RAW"

  MAPS_RAW=$(get_live_version "/opt/${EXPANSION}_maps_version.spp")
  IFS='|' read -r MAPS_VER _ <<< "$MAPS_RAW"
  
  WEB_RAW=$(get_live_version "/opt/${EXPANSION}_website_version.spp")
  IFS='|' read -r WEB_VER _ <<< "$WEB_RAW"

  GREEN="\e[32m"
  RED="\e[31m"
  YELLOW="\e[33m"
  RESET="\e[0m"

  EXPECTED_CORE="${VERSION_MAP[$EXPANSION:CORE]:-}"
  EXPECTED_WORLD="${VERSION_MAP[$EXPANSION:WORLD]:-}"

  [[ "$CORE_VER" == "$EXPECTED_CORE" ]] && CORE_COLOR=$GREEN || CORE_COLOR=$RED
  [[ "$WORLD_VER" == "$EXPECTED_WORLD" ]] && WORLD_COLOR=$GREEN || WORLD_COLOR=$RED

  echo -e "Core: ${CORE_COLOR}v${CORE_VER:-NA}${RESET} (${CORE_BRANCH:-?}@${CORE_COMMIT:-?})"
  echo -e "Bots: ${YELLOW}${BOT_BRANCH:-?}@${BOT_COMMIT:-?}${RESET}"
  echo "Built: ${BUILD_DATE:-unknown}"
  echo -e "World: ${WORLD_COLOR}${WORLD_VER:-NA}${RESET}"
  echo "Chars: ${CHARS_VER:-NA}  Realm: ${REALM_VER:-NA}  Maps: ${MAPS_VER:-NA}"
  echo "Web: ${WEB_VER:-NA}  Logs: ${LOGS_VER:-NA}"
}

get_live_version() {
  local FILE=$1

  pct exec "$DB_CTID" -- bash -c "
    if [[ -f '$FILE' ]]; then
      cat '$FILE'
    else
      echo NOT_INSTALLED
    fi
  " 2>/dev/null || echo NOT_INSTALLED
}

live_logs() {
  echo "Press Ctrl+C to exit live view."
  pct exec "$GAME_CTID" -- tail -f /var/log/mangos/Server.log
}

ensure_shared_stack() {

  if [[ -n "$DB_CTID" && -n "$WEB_CTID" && -n "$LOGIN_CTID" ]]; then
    return
  fi

  echo
  echo "Shared SPP services missing."
  read -p "Create shared stack now? (y/n): " CONFIRM
  [[ "$CONFIRM" != "y" ]] && return 1

  pct list
  echo

  read -p "Enter CTID for spp-db: " DB_NEW
  read -p "Enter CTID for spp-web: " WEB_NEW
  read -p "Enter CTID for spp-login: " LOGIN_NEW

  create_container "spp-db" "mariadb" "$DB_NEW" 1
  create_container "spp-web" "website" "$WEB_NEW" 2
  create_container "spp-login" "login" "$LOGIN_NEW" 3

  auto_detect_stack

  DB_CTID="$DB_CTID"
  WEB_CTID="$WEB_CTID"
  LOGIN_CTID="$LOGIN_CTID"
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

    [[ -n "$EXPANSION" ]] && echo "S - Shared Services"
    echo "0 - Exit"
    echo

    read -p "Selection: " SEL

    [[ "$SEL" == "0" ]] && exit 0

    if [[ "$SEL" =~ ^[Ss]$ ]]; then
      shared_services_menu
      continue
    fi

    INDEX=$((SEL-1))
    EXPANSION="${ALLOWED_EXPANSIONS[$INDEX]}"
    [[ -n "$EXPANSION" ]] && return
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
  echo
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
cd /opt/spp-sql
git fetch --depth 1 origin
git reset --hard origin/HEAD
    "
  done
}
update_repo() {
  update_sql_repo
  update_settings_repo
}

shared_config_menu() {
  echo
  echo "Configuration"
  echo
  echo "1 - Correct Server Confs"
  echo "2 - Fix Realmlist"
  echo "3 - Create Services"
  echo
  echo "0 - Back"

  read -p "Selection: " C

  case "$C" in
    1) update_db_conf ;;
    2) fix_realm_entry ;;
    3) service_create ;;
  esac
}
update_db_conf() {
if [[ -z "${EXPANSION:-}" ]]; then
  echo "Select expansion:"
  select EXP in classic tbc wotlk; do
    [[ -n "$EXP" ]] && EXPANSION="$EXP" && break
  done
fi
  derive_db_names || return 1

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')

  # Update realmd.conf (login LXC)
  pct exec "$LOGIN_CTID" -- bash -c "
  sed -i \
  's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
  ${INSTALL_DIR}/etc/realmd.conf
  "

for EXP in "${!GAME_CTIDS[@]}"; do
  GAME_CTID="${GAME_CTIDS[$EXP]}"
  MAP_KEY="$EXP"
  derive_db_names || continue

  pct exec "$GAME_CTID" -- bash -c "
  sed -i \
  -e 's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
  -e 's|^WorldDatabaseInfo *=.*|WorldDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
  -e 's|^CharacterDatabaseInfo *=.*|CharacterDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
  -e 's|^LogsDatabaseInfo *=.*|LogsDatabaseInfo      = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' \
  ${INSTALL_DIR}/etc/mangosd.conf
  "
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

  # realmd
  pct exec "$LOGIN_CTID" -- bash -c "
cat > /etc/systemd/system/realmd.service <<EOF
[Unit]
Description=CMaNGOS Realmd
After=network.target mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bin/realmd -c $INSTALL_DIR/etc/realmd.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF
"

  pct exec "$LOGIN_CTID" -- systemctl daemon-reload

  # mangosd
  pct exec "$GAME_CTID" -- bash -c "
cat > /etc/systemd/system/mangosd.service <<EOF
[Unit]
Description=CMaNGOS World Server
After=network.target mariadb.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bin/mangosd -c $INSTALL_DIR/etc/mangosd.conf
Restart=always
RestartSec=5

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

  LOGIN_IP=$(pct exec "$GAME_CTID" -- hostname -I | awk '{print $1}')

  pct exec "$DB_CTID" -- bash -c "
  export MYSQL_PWD='${DB_ROOT_PASS}'

  mariadb -u root ${REALM_DB_NAME} -e \"
    DELETE FROM realmlist WHERE id=${REALM_ID};
    INSERT INTO realmlist
    (id,name,address,port,icon,realmflags,timezone,allowedSecurityLevel)
    VALUES
    (${REALM_ID},'SPP-${EXPANSION^}','${LOGIN_IP}',8085,1,0,1,0);
  \"
  "

}





shared_website_menu() {
  echo
  echo "Website"
  echo
  echo "1 - Install Website"
  echo "2 - Update Website"
  echo
  echo "0 - Back"

  read -p "Selection: " W

  case "$W" in
    1) install_website ;;
    2) update_website ;;
  esac
}
install_website() {

  derive_db_names || return 1

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')
  DB_PORT="${DB_PORT:-3306}"

  case "$EXPANSION" in
    classic)
      REALM_DB="classicrealmd"
      WORLD_DB="classicmangos"
      ;;
    tbc)
      REALM_DB="tbcrealmd"
      WORLD_DB="tbcmangos"
      ;;
    wotlk)
      REALM_DB="wotlkrealmd"
      WORLD_DB="wotlkmangos"
      ;;
  esac

  echo
  echo "Installing Custom Armory Website..."
  echo

  pct exec "$WEB_CTID" -- bash -c "
  set -e
  cd /opt

  rm -rf SPP-Armory-Website
  git clone https://github.com/japtenks/SPP-Armory-Website.git

  rm -rf /var/www/html/*
  cp -r SPP-Armory-Website/* /var/www/html/

  chown -R www-data:www-data /var/www/html
  chmod -R 755 /var/www/html
  "

  pct exec "$WEB_CTID" -- bash -c "
  a2enmod rewrite >/dev/null 2>&1 || true
  systemctl restart apache2
  "

  echo
  echo "Custom website installed."
  read -p "Press Enter to continue..."
  
  install_website_db
  web_config
  
WEB_EXPECTED="${VERSION_MAP[$EXPANSION:WEBSITE]}"
INSTALL_DATE=$(date +%F_%H:%M)

write_version "${EXPANSION}_website_version.spp" \
"${WEB_EXPECTED}|${INSTALL_DATE}"
  
}
install_website_db() {

  derive_db_names || return 1

  case "$EXPANSION" in
    classic) SQL_EXP="vanilla" ;;
    tbc)     SQL_EXP="tbc" ;;
    wotlk)   SQL_EXP="wotlk" ;;
  esac

  TARGET_DB="$REALM_DB"
  BASE="/opt/spp-sql/sql/${SQL_EXP}"
  VERSION_FILE="/opt/${EXPANSION}_website_version.spp"

  echo "Installing Website DB..."

  pct exec "$DB_CTID" -- bash -c "
    set -e
    cd $BASE

    mariadb -u root -p$DB_ROOT_PASS $TARGET_DB < website.sql
	mariadb -u root -p$DB_ROOT_PASS $TARGET_DB < website_news.sql
  "
    echo "Website DB installed."
    TARGET_DB="${EXPANSION}armory"
    echo "Installing ${EXPANSION}armory DB..."
	 
    pct exec "$DB_CTID" -- bash -c "
    set -e
    cd $BASE

    if [ ! -f armory.7z ]; then
      echo 'armory.7z not found.'
      exit 1
    fi

    7z x -y armory.7z >/dev/null

    mariadb -u root -p$DB_ROOT_PASS $TARGET_DB < armory.sql
	mariadb -u root -p$DB_ROOT_PASS $TARGET_DB < armory_tooltip.sql
    mariadb -u root -p$DB_ROOT_PASS $TARGET_DB < bot_command.sql
    rm -f armory.sql
  "

  pct exec "$DB_CTID" -- bash -c "echo 0 > $VERSION_FILE"

  echo "Armory DB installed."
}
update_website() {

  derive_db_names || return 1
  
  echo
  echo "Updating Custom Armory Website..."
  echo

  pct exec "$WEB_CTID" -- bash -c "
  set -e
  cd /opt/SPP-Armory-Website

  git fetch
  git reset --hard origin/HEAD

  rm -rf /var/www/html/*
  cp -r /opt/SPP-Armory-Website/* /var/www/html/

  chown -R www-data:www-data /var/www/html
  chmod -R 755 /var/www/html

  systemctl restart apache2
  "

  echo
  echo "Custom website updated."
  read -p 'Press Enter to continue...'
}
web_config(){
#call  derive_db_names || return 1 if called out of function
 pct exec "$WEB_CTID" -- bash -c "cat > /var/www/html/config/config-protected.php" <<EOF
<?php
\$realmd = array(
'db_type' => 'mysql',
'db_host' => '$DB_IP',
'db_port' => '3306',
'db_username' => '$DB_LAN_USER',
'db_password' => '$DB_LAN_PASS',
'db_name' => '$REALM_DB',
'db_encoding' => 'utf8',
);

\$worlddb = array(
'db_type' => 'mysql',
'db_host' => '$DB_IP',
'db_port' => '3306',
'db_username' => '$DB_LAN_USER',
'db_password' => '$DB_LAN_PASS',
'db_name' => '$WORLD_DB',
'db_encoding' => 'utf8',
);

\$DB = \$worlddb;
?>
EOF

pct exec "$WEB_CTID" -- bash -c "cat > /var/www/html/armory/configuration/mysql.php" <<EOF
<?php
\$realms = array(
"Vanilla Realm" => array(1,1,1,1,1),
);

define("DefaultRealmName","Vanilla Realm");

\$realmd_DB = array(
1 => array("$DB_IP:3306","$DB_LAN_USER","$DB_LAN_PASS","$REALM_DB"),
);

\$characters_DB = array(
1 => array("$DB_IP:3306","$DB_LAN_USER","$DB_LAN_PASS","${EXPANSION}characters"),
);

\$mangosd_DB = array(
1 => array("$DB_IP:3306","$DB_LAN_USER","$DB_LAN_PASS","$WORLD_DB"),
);

\$armory_DB = array(
1 => array("$DB_IP:3306","$DB_LAN_USER","$DB_LAN_PASS","${EXPANSION}armory"),
);

\$playerbot_DB = array(
1 => array("$DB_IP:3306","$DB_LAN_USER","$DB_LAN_PASS","${EXPANSION}playerbots"),
);
?>
EOF
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

maintenance_menu() {
  while true; do
    clear
    print_banner
    echo "Maintenance"
    echo
    echo "1 - Core"
    echo "2 - Database"
    echo "3 - Install Data Pack"
    echo
    echo "I - Full Install"
    echo "U - Update Setting Repo"	
    echo "0 - Back"
    echo

    read -p "Selection: " MSEL

    case "$MSEL" in
      1) core_menu ;;
      2) database_menu ;;
      3) update_maps ;;
      I)
        read -p "Type YES to continue: " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && full_install
        ;;
	  U)
	    read -p "Type YES to continue: " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && sync_settings_repo ;;
      0) return ;;
    esac
  done
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



















core_menu() {
  while true; do
    clear
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
        read -p "Confirm update? (Y/N): " CONFIRM
        if [[ "$CONFIRM" == "Y" ]]; then
          pct exec "$GAME_CTID" -- bash -c "
            cd /opt/source &&
            git pull &&
            cd build &&
            make -j\$(nproc) &&
            make install
          "
        fi
        ;;
      0) return ;;
    esac
  done
}
database_menu() {
  while true; do
    clear
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
	echo "6 - Update playerbot DB"
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
	    read -p "Confirm update on playerbot? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && update_db_type playerbot ;;
      0) return ;;
    esac
  done
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

stack_control_menu() {
  while true; do
    clear
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

server_info_menu() {
  auto_detect_stack
  LOGIN_IP=$(pct exec "$LOGIN_CTID" -- hostname -I | awk '{print $1}')

  while true; do
    clear
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
    echo "3 - Change Server Address"
    echo "4 - Change Realm Name"
    echo "5 - Server Logs"
    echo "6 - Crash Logs"
    echo
    echo "0 - Back"
    echo

    read -p "Enter your choice: " INFO

    case "$INFO" in
      1) edit_world_settings ;;
      2) edit_bot_settings ;;
      3) change_server_address ;;
      4) change_realm_name ;;
      5) live_logs ;;
      6) view_crash_logs ;;
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




#program starts here
main
