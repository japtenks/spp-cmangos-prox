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

DB_HOST=""
DB_ROOT_PASS="$DB_ROOT_PASS"

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

  for TYPE in WORLD CORE REALM CHARS LOGS MAPS; do
    VAR="${KEY}_${TYPE}_VERSION"
    VERSION_MAP["$EXP:$TYPE"]="${!VAR:-0}"
  done
done
##HELPERS
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

  CMD=(
    pct create "$CTID" "$DEFAULT_TEMPLATE"
    --hostname "$NAME"
    --cores "$CORES"
    --memory "$RAM"
    --rootfs "${STORAGE}:${DISK}"
    --net0 "name=eth0,bridge=vmbr0,ip=dhcp"
    --unprivileged 1
    --onboot 1
    --startup "order=$START_ORDER"
	--features nesting=1
    --features keyctl=1
  )

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY RUN]"
    printf '%q ' "${CMD[@]}"
    echo
    return
else
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
    pct exec "$CTID" -- apt install -y apache2 php libapache2-mod-php
    pct exec "$CTID" -- systemctl enable apache2
    ;;
  game)
    pct exec "$CTID" -- apt install -y \
      git build-essential cmake \
      libssl-dev libbz2-dev libreadline-dev \
      libncurses-dev libmariadb-dev libmariadb-dev-compat \
      libboost-all-dev libace-dev unzip wget p7zip-full
	;;
esac
  fi
  
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

  # Update mangosd.conf (game LXC)
  pct exec "$GAME_CTID" -- bash -c "
  sed -i \
  -e 's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
  -e 's|^WorldDatabaseInfo *=.*|WorldDatabaseInfo     = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
  -e 's|^CharacterDatabaseInfo *=.*|CharacterDatabaseInfo = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
  -e 's|^LogsDatabaseInfo *=.*|LogsDatabaseInfo      = \"${DB_IP};3306;${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' \
  ${INSTALL_DIR}/etc/mangosd.conf
  "

}

full_install() {

  derive_db_names || return 1
  
  echo
  echo "  FULL INSTALL will:"
  echo " - Stop services"
  echo " - Delete $INSTALL_DIR"
  echo " - Drop ALL ${EXPANSION} databases"
  echo " - Remove source + build files"
  echo
  read -p "Type YES to continue: " CONFIRM

  if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    return 1
  fi



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

create_lan_db_user() {
  derive_db_names || return 1

  pct exec "$DB_CTID" -- bash -c "
  export MYSQL_PWD='${DB_ROOT_PASS}'

  mariadb -u root -e \"
  CREATE USER IF NOT EXISTS '${DB_LAN_USER}'@'${DB_LAN_HOST}' IDENTIFIED BY '${DB_LAN_PASS}';
  GRANT ALL PRIVILEGES ON ${WORLD_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${CHAR_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${REALM_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  GRANT ALL PRIVILEGES ON ${LOG_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  FLUSH PRIVILEGES;
  \"
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
    https://github.com/celguar/spp-classics-cmangos.git spp-sql

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
make install
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

apply_autostart_setting() {

  if [[ "$AUTO_START" == "1" ]]; then
    pct exec "$LOGIN_CTID" -- systemctl enable realmd
    pct exec "$GAME_CTID" -- systemctl enable mangosd
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
  else
    AUTO_START="1"
  fi

  # update config.env
  sed -i "s/^AUTO_START=.*/AUTO_START=\"$AUTO_START\"/" "$CONFIG_FILE"

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

connect_ra() {
  echo "Fetching world IP..."
  IP=$(pct exec "$GAME_CTID" -- hostname -I | awk '{print $1}')

  if [[ -z "$IP" ]]; then
    echo "Could not determine IP."
    return 1
  fi

  echo "Connecting to RA at $IP:3443"
  echo "Type 'quit' to exit, when logged in."
  echo
  telnet "$IP" 3443
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
  echo
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
  echo "Chars: ${CHARS_VER:-NA}  Realm: ${REALM_VER:-NA}  Logs: ${LOGS_VER:-NA}  Maps: ${MAPS_VER:-NA}"
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
  pct exec "$GAME_CTID" -- journalctl -u mangosd -f --no-pager
}

shared_services_menu() {
  while true; do
    echo
    echo "Shared Services"
    echo
    echo "1 - Status"
    echo "2 - Start DB"
    echo "3 - Stop DB"
    echo "4 - Start Login"
    echo "5 - Stop Login"
    echo "6 - Start Web"
    echo "7 - Stop Web"
    echo "u - update_db_conf()"
    echo "f - fix_realm_entry()"
    echo "s - service_create()"
    echo 
    echo "0 - Back"
    echo

    read -p "Selection: " SS

    case "$SS" in
      1)
        for CT in "$DB_CTID" "$LOGIN_CTID" "$WEB_CTID"; do
          NAME=$(pct config "$CT" | awk -F': ' '/hostname/ {print $2}')
          echo
          echo "$NAME ($CT)"
          pct status "$CT"
          pct exec "$CT" -- uptime
        done
        ;;
      2) pct start "$DB_CTID" ;;
      3) pct stop "$DB_CTID" ;;
      4) pct start "$LOGIN_CTID" ;;
      5) pct stop "$LOGIN_CTID" ;;
      6) pct start "$WEB_CTID" ;;
      7) pct stop "$WEB_CTID" ;;
	  u) 
	  echo "# Update mangosd.conf (game LXC)"
      echo "# Update realmd.conf (login LXC)"
         update_db_conf ;;
	  f) echo "# Update realmlist (db LXC)"
         fix_realm_entry ;;
	  s) echo "# Login/Game LXC) systemd creations"
         service_create ;;
      0) break ;;
    esac
  done
}

# =========================================
# MASTER LOOP
# =========================================
while true; do

  # =====================================
  # EXPANSION + SHARED SERVICES MENU
  # =====================================
  while true; do
    clear
    echo -e "\e[0m"
	print_banner
	echo
    echo "Choose Expansion:"
    echo
GAME_CTIDS=()
  auto_detect_stack


for i in "${!ALLOWED_EXPANSIONS[@]}"; do
  EXP="${ALLOWED_EXPANSIONS[$i]}"
  CTID="${GAME_CTIDS[$EXP]:-}"

      if [[ -n "$CTID" ]]; then
        STATUS="[Installed - CTID $CTID]"
      else
        STATUS="[Not Installed]"
      fi

      echo "$((i+1)) - ${EXP^}"
      echo "       $STATUS"
      echo
    done

    echo "S - Shared Services (DB/Web/Login)"
    echo "0 - Exit"
    echo

    read -p "Selection: " SEL

    # Global Exit
    [[ "$SEL" == "0" ]] && exit 0

    # Shared Services Menu
    if [[ "$SEL" =~ ^[Ss]$ ]]; then
      shared_services_menu
      continue
    fi

    INDEX=$((SEL-1))
    EXPANSION="${ALLOWED_EXPANSIONS[$INDEX]}"

    if [[ -n "$EXPANSION" ]]; then
      break
    else
      echo "Invalid selection."
    fi
  done
# -----------------------------------------
# Detect Shared Stack
# -----------------------------------------
auto_detect_stack

DB_CTID="$DB_CTID"
WEB_CTID="$WEB_CTID"
LOGIN_CTID="$LOGIN_CTID"
GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"

if [[ -z "$DB_CTID" || -z "$WEB_CTID" || -z "$LOGIN_CTID" ]]; then
  echo
  echo "Shared SPP services missing."
  read -p "Create shared stack now? (y/n): " CONFIRM
  [[ "$CONFIRM" != "y" ]] && continue

  pct list

  read -p "Enter CTID for spp-db: " DB_NEW
  read -p "Enter CTID for spp-web: " WEB_NEW
  read -p "Enter CTID for spp-login: " LOGIN_NEW
  

  create_container "spp-db" "mariadb" "$DB_NEW" 1
  create_container "spp-web" "website" "$WEB_NEW" 2
  create_container "spp-login" "login" "$LOGIN_NEW" 3
  

  auto_detect_stack
fi

  if [[ -z "$GAME_CTID" ]]; then
    echo
    echo "Game container spp-$EXPANSION not found."
    read -p "Create it now? (y/n): " CONFIRM
    [[ "$CONFIRM" != "y" ]] && continue

    pct list
    read -p "Enter CTID for spp-$EXPANSION: " NEW_CTID
    [[ ! "$NEW_CTID" =~ ^[0-9]+$ ]] && continue

    create_container "spp-$EXPANSION" "game" "$NEW_CTID" 4
    GAME_CTID="$NEW_CTID"
  fi

  # =========================================
  # SERVICE MENU
  # =========================================
  while true; do
    echo
    print_banner
	print_version
    echo "Stack: spp-$EXPANSION"
    echo
    echo "1 - Stack Control"
    echo "2 - Maintenance"
	echo
    echo "4 - Remote Console (RA)"
	echo "5 - Live World Log"
	echo
	echo "6 - Autostart ($AUTO_START)"
    echo "0 - Expansion Select"
    echo

    read -p "Selection: " MAIN

    case "$MAIN" in

      1)
        while true; do
          stat_state
          echo
          echo "$GAME_CTID - $EXPANSION Control"
          echo "Status: $STACK_STATUS"
          echo
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
            0) break ;;
          esac
        done
        ;;

      2)
        while true; do
          echo
          echo "Maintenance"
          echo
          echo "1 - Core"
          echo "2 - Database"
          echo "3 - Update Maps"
		  echo
		  echo "I - (Re)Install Full"
          echo "0 - Back"
          echo

          read -p "Selection: " MSEL

          case "$MSEL" in

            1)
              while true; do
                echo
                echo "Core Maintenance"
                echo
                echo "1 - Clean Rebuild Core"
                echo "2 - Incremental Core Update"
                echo "0 - Back"
                echo

                read -p "Selection: " CORE

                case "$CORE" in
                  1)
                    read -p "CONFIRM Rebuild? (Y/N): " CONFIRM
                    [[ "$CONFIRM" == "Y" ]] && \
                    pct exec "$GAME_CTID" -- rm -rf /opt/source && \
                    comp_server
                    ;;
                  2)
                    read -p "Update recent? (Y/N): " CONFIRM
                    [[ "$CONFIRM" == "Y" ]] && \
                    pct exec "$GAME_CTID" -- bash -c "
                      cd /opt/source &&
                      git pull &&
                      cd build &&
                      make -j\$(nproc) &&
                      make install
                    "
                    ;;
				 
                  0)
                    break
					;;
                esac
              done
              ;;

            2)
              while true; do
                echo
                echo "Database Maintenance"
                echo
                echo "1 - Install Full DB"
                echo "2 - Reset Characters"
                echo "3 - Install Locales"
                echo "0 - Back"
                echo

                read -p "Selection: " DBSEL

                case "$DBSEL" in
                  1)
                    read -p "Full DB reinstall? (Y/N): " CONFIRM
                    [[ "$CONFIRM" == "Y" ]] && install_db
                    ;;
                  2)
                    read -p "Characters Reset? (Y/N): " CONFIRM
                    [[ "$CONFIRM" == "Y" ]] && reset_characters
                    ;;
                  3)
                    install_locales
                    ;;
                  0) break ;;
                esac
              done
              ;;

            3)
              update_maps
              ;;
            I)
			full_install
			  ;;
            0)
              break
              ;;
          esac
        done
        ;;

      4)
        connect_ra
        ;;
5)
  live_logs
  ;;

      0)
        break   # returns to expansion selection
        ;;

    esac
  done

done