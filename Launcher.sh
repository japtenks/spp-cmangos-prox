#!/bin/bash
set -euo pipefail
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LAUNCHER_VERSION="22"
DEFAULT_CRASH_SHARE_ROOT="/mnt/fast/crashlogs"
DEFAULT_CMANGOS_STANDARD_REPO_URL="https://github.com/cmangos/mangos-classic.git"
DEFAULT_CMANGOS_STANDARD_GIT_BRANCH="master"
DEFAULT_CMANGOS_REPO_URL="https://github.com/japtenks/mangos-classic.git"
DEFAULT_CMANGOS_GIT_BRANCH="ike3-bots"
DEFAULT_TORTOISE_REPO_URL="https://github.com/faemwow/tortoise-wow.git"
DEFAULT_TORTOISE_GIT_BRANCH="main"
DEFAULT_VMANGOS_REPO_URL="https://github.com/japtenks/SPP-Vmangos-nix.git"
DEFAULT_VMANGOS_GIT_BRANCH="codex/ahbot-next"
DEFAULT_VMANGOS_BRIDGE_REPO_URL="$DEFAULT_VMANGOS_REPO_URL"
DEFAULT_VMANGOS_AHBOT_REPO_URL="$DEFAULT_VMANGOS_REPO_URL"
DEFAULT_VMANGOS_BRIDGE_BRANCH="$DEFAULT_VMANGOS_GIT_BRANCH"
DEFAULT_VMANGOS_AHBOT_BRANCH="$DEFAULT_VMANGOS_GIT_BRANCH"

# -------------------------
# First Run Bootstrap
# -------------------------
CONFIG_FILE_PLAIN="${SCRIPT_DIR}/config.env"
CONFIG_FILE_ENC="${SCRIPT_DIR}/config.env.enc"
CONFIG_FILE="$CONFIG_FILE_PLAIN"
CONFIG_RUNTIME_FILE=""
CONFIG_STORAGE_MODE="plain"
CONFIG_ENV_ENCRYPTION="0"
CONFIG_ENCRYPTION_PASSPHRASE=""
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

cleanup_runtime_config() {
  if [[ -n "${CONFIG_RUNTIME_FILE:-}" && -f "${CONFIG_RUNTIME_FILE}" ]]; then
    rm -f "${CONFIG_RUNTIME_FILE}"
  fi
}

ensure_runtime_config_copy() {
  local source_file="$1"
  [[ -f "$source_file" ]] || return 1

  if [[ -z "${CONFIG_RUNTIME_FILE:-}" || ! -f "${CONFIG_RUNTIME_FILE}" ]]; then
    CONFIG_RUNTIME_FILE=$(mktemp "${TMPDIR:-/tmp}/spp-config.XXXXXX")
  fi

  cp "$source_file" "${CONFIG_RUNTIME_FILE}"
  chmod 600 "${CONFIG_RUNTIME_FILE}" 2>/dev/null || true
  CONFIG_FILE="${CONFIG_RUNTIME_FILE}"
}

prompt_config_passphrase() {
  local mode="${1:-unlock}"
  local pass_one=""
  local pass_two=""

  if [[ "$mode" == "new" ]]; then
    read -rsp "New config encryption passphrase: " pass_one
    echo
    [[ -n "$pass_one" ]] || { echo "Passphrase cannot be empty."; return 1; }
    read -rsp "Confirm passphrase: " pass_two
    echo
    [[ "$pass_one" == "$pass_two" ]] || { echo "Passphrases did not match."; return 1; }
  else
    read -rsp "Config encryption passphrase: " pass_one
    echo
    [[ -n "$pass_one" ]] || { echo "Passphrase cannot be empty."; return 1; }
  fi

  CONFIG_ENCRYPTION_PASSPHRASE="$pass_one"
}

load_existing_config_storage() {
  if [[ -f "$CONFIG_FILE_PLAIN" ]]; then
    CONFIG_FILE="$CONFIG_FILE_PLAIN"
    CONFIG_STORAGE_MODE="plain"
    return 0
  fi

  if [[ -f "$CONFIG_FILE_ENC" ]]; then
    command -v openssl >/dev/null 2>&1 || {
      echo "Encrypted config detected at ${CONFIG_FILE_ENC}, but openssl is not installed."
      exit 1
    }

    prompt_config_passphrase "unlock" || exit 1
    ensure_runtime_config_copy "$CONFIG_FILE_ENC"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -in "$CONFIG_FILE_ENC" -out "$CONFIG_FILE" -pass pass:"$CONFIG_ENCRYPTION_PASSPHRASE" >/dev/null 2>&1; then
      echo "Failed to decrypt ${CONFIG_FILE_ENC}. Wrong passphrase or damaged file."
      exit 1
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    CONFIG_STORAGE_MODE="encrypted"
    return 0
  fi

  CONFIG_FILE="$CONFIG_FILE_PLAIN"
  CONFIG_STORAGE_MODE="plain"
}

persist_config_storage() {
  if [[ "${CONFIG_STORAGE_MODE:-plain}" == "encrypted" || "${CONFIG_ENV_ENCRYPTION:-0}" == "1" ]]; then
    command -v openssl >/dev/null 2>&1 || {
      echo "Config encryption requires openssl."
      return 1
    }

    if [[ -z "${CONFIG_ENCRYPTION_PASSPHRASE:-}" ]]; then
      prompt_config_passphrase "unlock" || return 1
    fi

    if [[ "$CONFIG_FILE" == "$CONFIG_FILE_PLAIN" ]]; then
      ensure_runtime_config_copy "$CONFIG_FILE_PLAIN" || return 1
    fi

    if ! openssl enc -aes-256-cbc -salt -pbkdf2 -in "$CONFIG_FILE" -out "$CONFIG_FILE_ENC" -pass pass:"$CONFIG_ENCRYPTION_PASSPHRASE" >/dev/null 2>&1; then
      echo "Failed to encrypt config to ${CONFIG_FILE_ENC}."
      return 1
    fi

    chmod 600 "$CONFIG_FILE_ENC" 2>/dev/null || true
    rm -f "$CONFIG_FILE_PLAIN"
    CONFIG_STORAGE_MODE="encrypted"
  else
    if [[ "$CONFIG_FILE" != "$CONFIG_FILE_PLAIN" ]]; then
      cp "$CONFIG_FILE" "$CONFIG_FILE_PLAIN"
    fi
    chmod 600 "$CONFIG_FILE_PLAIN" 2>/dev/null || true
    rm -f "$CONFIG_FILE_ENC"
    CONFIG_STORAGE_MODE="plain"
  fi
}

trap cleanup_runtime_config EXIT

normalize_config_env() {
  [[ -f "$CONFIG_FILE" ]] || return 0

  # Canonical install-path ordering is owned by the launcher and must survive old configs.
  set_or_append_config_line "ALLOWED_EXPANSIONS" '("classic" "tbc" "wotlk" "vmangos")'
  set_or_append_config_line "LAUNCHER_VERSION" "\"${DEFAULT_LAUNCHER_VERSION}\""
  append_config_default_line "CONFIG_ENV_ENCRYPTION" '"0"'
  append_config_default_line "LAUNCHER_AUTO_UPDATE_ON_START" '"0"'
  append_config_default_line "LAUNCHER_GIT_BRANCH" '"unknown"'
  append_config_default_line "LAUNCHER_GIT_COMMIT" '"unknown"'
  append_config_default_line "WEBSITE_GIT_BRANCH" '"unknown"'
  append_config_default_line "WEBSITE_GIT_COMMIT" '"unknown"'
  append_config_default_line "WEBSITE_GIT_DATE" '"unknown"'
  append_config_default_line "WEBSITE_REMOTE_GIT_BRANCH" '"unknown"'
  append_config_default_line "WEBSITE_REMOTE_GIT_COMMIT" '"unknown"'
  append_config_default_line "WEBSITE_REMOTE_GIT_DATE" '"unknown"'
  append_config_default_line "WEBSITE_GIT_OUTDATED" '"0"'

  append_config_default_line "CMANGOS_BUILD_PROFILE" '"repo"'
  append_config_default_line "CMANGOS_STANDARD_REPO_URL" "\"${DEFAULT_CMANGOS_STANDARD_REPO_URL}\""
  append_config_default_line "CMANGOS_STANDARD_GIT_BRANCH" "\"${DEFAULT_CMANGOS_STANDARD_GIT_BRANCH}\""
  append_config_default_line "CMANGOS_REPO_URL" "\"${DEFAULT_CMANGOS_REPO_URL}\""
  append_config_default_line "CMANGOS_GIT_BRANCH" "\"${DEFAULT_CMANGOS_GIT_BRANCH}\""
  append_config_default_line "CLASSIC_INSTANCE_NAMES" '("main")'
  append_config_default_line "TBC_INSTANCE_NAMES" '("main")'
  append_config_default_line "TORTOISE_REPO_URL" "\"${DEFAULT_TORTOISE_REPO_URL}\""
  append_config_default_line "TORTOISE_GIT_BRANCH" "\"${DEFAULT_TORTOISE_GIT_BRANCH}\""
  append_config_default_line "VMANGOS_INSTANCE_NAMES" '("main" "ahbot")'
  append_config_default_line "IP_VMANGOS" '""'
  append_config_default_line "VMANGOS_REPO_URL" "\"${DEFAULT_VMANGOS_BRIDGE_REPO_URL}\""
  append_config_default_line "VMANGOS_GIT_BRANCH" "\"${DEFAULT_VMANGOS_BRIDGE_BRANCH}\""
  append_config_default_line "VMANGOS_MAIN_REPO_URL" "\"${DEFAULT_VMANGOS_BRIDGE_REPO_URL}\""
  append_config_default_line "VMANGOS_MAIN_GIT_BRANCH" "\"${DEFAULT_VMANGOS_BRIDGE_BRANCH}\""
  append_config_default_line "VMANGOS_AHBOT_REPO_URL" "\"${DEFAULT_VMANGOS_AHBOT_REPO_URL}\""
  append_config_default_line "VMANGOS_AHBOT_GIT_BRANCH" "\"${DEFAULT_VMANGOS_AHBOT_BRANCH}\""
  append_config_default_line "VMANGOS_DB_HOST" '""'
  append_config_default_line "VMANGOS_DB_PORT" '"3306"'
  append_config_default_line "VMANGOS_WORLD_DB_URL" '"https://github.com/brotalnia/database/raw/master/world_full_14_june_2021.7z"'
  append_config_default_line "VMANGOS_DATA_PACK_URL" '"https://github.com/japtenks/spp-cmangos-prox/releases/download/assets/vmangos-bropack-v25.zip"'
  append_config_default_line "CRASH_SHARE_ROOT" "\"${DEFAULT_CRASH_SHARE_ROOT}\""
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
  append_config_default_line "VMANGOS_SHARED_REALMD" '"0"'
}

persist_launcher_auto_update_flag() {
  local value="${1:-0}"
  [[ -f "$CONFIG_FILE" ]] || return 0
  set_or_append_config_line "LAUNCHER_AUTO_UPDATE_ON_START" "\"${value}\""
  LAUNCHER_AUTO_UPDATE_ON_START="$value"
  persist_config_storage
}

mark_launcher_clean_exit() {
  persist_launcher_auto_update_flag "1"
}

mark_launcher_unclean_exit() {
  persist_launcher_auto_update_flag "0"
}

exit_launcher_cleanly() {
  mark_launcher_clean_exit
  exit 0
}

handle_launcher_error() {
  local line_no="$1"
  local command="$2"
  local exit_code="${3:-1}"
  mark_launcher_unclean_exit
  echo "ERROR at line ${line_no}: ${command}" >&2
  exit "$exit_code"
}

handle_launcher_interrupt() {
  local signal="${1:-INT}"
  mark_launcher_unclean_exit
  echo
  echo "Interrupted by ${signal}. Auto-update disabled until the next clean exit."
  exit 130
}

trap 'handle_launcher_error "$LINENO" "$BASH_COMMAND" "$?"' ERR
trap 'handle_launcher_interrupt INT' INT
trap 'handle_launcher_interrupt TERM' TERM

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
  persist_config_storage
}

refresh_website_git_tracking() {
  local branch="unknown"
  local commit="unknown"
  local commit_date="unknown"
  local target_repo="${WEBSITE_SRC_DIR}"

  auto_detect_stack

  if [[ -n "${WEB_CTID:-}" ]] && ! pct exec "$WEB_CTID" -- test -d "${target_repo}/.git" 2>/dev/null; then
    target_repo="/var/www/html"
  fi

  if [[ -n "${WEB_CTID:-}" ]] && pct exec "$WEB_CTID" -- test -d "${target_repo}/.git" 2>/dev/null; then
    branch=$(pct exec "$WEB_CTID" -- bash -c "git -C '${target_repo}' rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown" | tr -d '\r' | tail -n 1)
    commit=$(pct exec "$WEB_CTID" -- bash -c "git -C '${target_repo}' rev-parse --short=12 HEAD 2>/dev/null || echo unknown" | tr -d '\r' | tail -n 1)
    commit_date=$(pct exec "$WEB_CTID" -- bash -c "git -C '${target_repo}' log -1 --date=short --format=%cd 2>/dev/null || echo unknown" | tr -d '\r' | tail -n 1)
  fi

  set_or_append_config_line "WEBSITE_GIT_BRANCH" "\"${branch}\""
  set_or_append_config_line "WEBSITE_GIT_COMMIT" "\"${commit}\""
  set_or_append_config_line "WEBSITE_GIT_DATE" "\"${commit_date}\""

  WEBSITE_GIT_BRANCH="$branch"
  WEBSITE_GIT_COMMIT="$commit"
  WEBSITE_GIT_DATE="$commit_date"
  persist_config_storage
}

update_launcher_self() {
  local mode="${1:-manual}"
  local upstream_ref=""
  echo
  echo "Updating launcher from git..."
  echo

  git -C "$SCRIPT_DIR" fetch --all --prune || {
    echo "Launcher fetch failed."
    [[ "$mode" == "manual" ]] && read -p "Press Enter to continue..." _
    return 1
  }

  upstream_ref=$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -z "$upstream_ref" ]]; then
    echo "Launcher update failed: no upstream tracking branch is configured."
    [[ "$mode" == "manual" ]] && read -p "Press Enter to continue..." _
    return 1
  fi

  if git -C "$SCRIPT_DIR" merge-base --is-ancestor HEAD "$upstream_ref" >/dev/null 2>&1; then
    git -C "$SCRIPT_DIR" merge --ff-only "$upstream_ref" || {
      echo "Launcher update failed."
      [[ "$mode" == "manual" ]] && read -p "Press Enter to continue..." _
      return 1
    }
  else
    if ! git -C "$SCRIPT_DIR" diff --quiet --ignore-submodules -- || \
       ! git -C "$SCRIPT_DIR" diff --cached --quiet --ignore-submodules --; then
      echo "Launcher history was rewritten upstream, but local launcher changes are present."
      echo "Commit, stash, or discard local changes in ${SCRIPT_DIR} before retrying the update."
      [[ "$mode" == "manual" ]] && read -p "Press Enter to continue..." _
      return 1
    fi

    echo "Launcher history diverged from ${upstream_ref}; aligning to the rewritten upstream history."
    git -C "$SCRIPT_DIR" reset --hard "$upstream_ref" || {
      echo "Launcher update failed."
      [[ "$mode" == "manual" ]] && read -p "Press Enter to continue..." _
      return 1
    }
  fi

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

refresh_website_remote_git_tracking() {
  local remote_branch="unknown"
  local remote_commit="unknown"
  local remote_date="unknown"
  local outdated="0"
  local target_repo="${WEBSITE_SRC_DIR}"

  auto_detect_stack

  if [[ -n "${WEB_CTID:-}" ]] && ! pct exec "$WEB_CTID" -- test -d "${target_repo}/.git" 2>/dev/null; then
    target_repo="/var/www/html"
  fi

  if [[ -n "${WEB_CTID:-}" ]] && pct exec "$WEB_CTID" -- test -d "${target_repo}/.git" 2>/dev/null; then
    pct exec "$WEB_CTID" -- bash -c "git -C '${target_repo}' fetch --quiet origin >/dev/null 2>&1 || true"
    remote_branch=$(pct exec "$WEB_CTID" -- bash -c "
      branch=\$(git -C '${target_repo}' rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
      if [[ \"\$branch\" != \"unknown\" ]] && git -C '${target_repo}' show-ref --verify --quiet \"refs/remotes/origin/\$branch\"; then
        echo \"\$branch\"
      else
        echo unknown
      fi
    " | tr -d '\r' | tail -n 1)
    if [[ "$remote_branch" != "unknown" ]]; then
      remote_commit=$(pct exec "$WEB_CTID" -- bash -c "git -C '${target_repo}' rev-parse --short=12 'origin/${remote_branch}' 2>/dev/null || echo unknown" | tr -d '\r' | tail -n 1)
      remote_date=$(pct exec "$WEB_CTID" -- bash -c "git -C '${target_repo}' log -1 --date=short --format=%cd 'origin/${remote_branch}' 2>/dev/null || echo unknown" | tr -d '\r' | tail -n 1)
      outdated=$(pct exec "$WEB_CTID" -- bash -c "
        if [[ \$(git -C '${target_repo}' rev-parse HEAD 2>/dev/null || echo unknown) == \$(git -C '${target_repo}' rev-parse 'origin/${remote_branch}' 2>/dev/null || echo different) ]]; then
          echo 0
        elif git -C '${target_repo}' merge-base --is-ancestor HEAD 'origin/${remote_branch}' >/dev/null 2>&1; then
          echo 1
        else
          echo 0
        fi
      " | tr -d '\r' | tail -n 1)
    fi
  fi

  set_or_append_config_line "WEBSITE_REMOTE_GIT_BRANCH" "\"${remote_branch}\""
  set_or_append_config_line "WEBSITE_REMOTE_GIT_COMMIT" "\"${remote_commit}\""
  set_or_append_config_line "WEBSITE_REMOTE_GIT_DATE" "\"${remote_date}\""
  set_or_append_config_line "WEBSITE_GIT_OUTDATED" "\"${outdated}\""

  WEBSITE_REMOTE_GIT_BRANCH="$remote_branch"
  WEBSITE_REMOTE_GIT_COMMIT="$remote_commit"
  WEBSITE_REMOTE_GIT_DATE="$remote_date"
  WEBSITE_GIT_OUTDATED="$outdated"
  persist_config_storage
}

run_startup_scan() {
  refresh_launcher_git_tracking
  refresh_website_git_tracking
  refresh_website_remote_git_tracking
}

run_startup_auto_update_if_needed() {
  if [[ "${LAUNCHER_AUTO_UPDATE_ON_START:-0}" == "1" ]]; then
    echo
    echo "Previous launcher session exited cleanly. Running startup auto-update..."
    mark_launcher_unclean_exit
    update_launcher_self "startup" || {
      echo "Startup auto-update skipped after a git error."
      sleep 1
    }
  fi
}

auto_detect_stack() {
  local _pct
  _pct=$(pct list) || return
  DB_CTID=$(awk '$3=="spp-db"    {print $1}' <<< "$_pct") || true
  WEB_CTID=$(awk '$3=="spp-web"  {print $1}' <<< "$_pct") || true
  LOGIN_CTID=$(awk '$3=="spp-login" {print $1}' <<< "$_pct") || true
  local _exp _ct _vm_target _vm_host _vm_name _cm_target
  local -a _vm_names
  GAME_CTIDS=()
  if declare -p VMANGOS_INSTANCE_NAMES >/dev/null 2>&1; then
    _vm_names=("${VMANGOS_INSTANCE_NAMES[@]}")
  else
    _vm_names=("main" "ahbot")
  fi
  for _cm_target in $(cmangos_target_list_all); do
    _ct=$(awk -v name="$(cmangos_target_hostname "$_cm_target")" '$3==name {print $1}' <<< "$_pct") || true
    [[ -n "$_ct" ]] && GAME_CTIDS[$_cm_target]=$_ct
  done
  for _vm_name in "${_vm_names[@]}"; do
    _vm_target="vmangos-${_vm_name}"
    _vm_host="spp-${_vm_target}"
    _ct=$(awk -v name="$_vm_host" '$3==name {print $1}' <<< "$_pct") || true
    if [[ -z "$_ct" && "$_vm_target" == "vmangos-main" ]]; then
      _ct=$(awk '$3=="spp-vmangos" {print $1}' <<< "$_pct") || true
    fi
    [[ -n "$_ct" ]] && GAME_CTIDS[$_vm_target]=$_ct
  done
  if [[ -n "${GAME_CTIDS[vmangos-main]:-}" && -z "${GAME_CTIDS[vmangos]:-}" ]]; then
    GAME_CTIDS[vmangos]="${GAME_CTIDS[vmangos-main]}"
  fi
  return 0
}

load_existing_config_storage

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
    read -p "Default crash share root on Proxmox host [$DEFAULT_CRASH_SHARE_ROOT]: " CRASH_SHARE_ROOT
    CRASH_SHARE_ROOT="${CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"

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
    read -p "Default crash share root on Proxmox host [$DEFAULT_CRASH_SHARE_ROOT]: " CRASH_SHARE_ROOT
    CRASH_SHARE_ROOT="${CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"
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
CONFIG_ENV_ENCRYPTION="0"
LAUNCHER_GIT_BRANCH="unknown"
LAUNCHER_GIT_COMMIT="unknown"
WEBSITE_GIT_BRANCH="unknown"
WEBSITE_GIT_COMMIT="unknown"
WEBSITE_GIT_DATE="unknown"
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
VMANGOS_WORLD_DB_URL="${VMANGOS_WORLD_DB_URL:-https://github.com/brotalnia/database/raw/master/world_full_14_june_2021.7z}"
VMANGOS_DATA_PACK_URL="${VMANGOS_DATA_PACK_URL:-https://github.com/japtenks/spp-cmangos-prox/releases/download/assets/vmangos-bropack-v25.zip}"
CMANGOS_BUILD_PROFILE="${CMANGOS_BUILD_PROFILE:-repo}"
CMANGOS_STANDARD_REPO_URL="${CMANGOS_STANDARD_REPO_URL:-$DEFAULT_CMANGOS_STANDARD_REPO_URL}"
CMANGOS_STANDARD_GIT_BRANCH="${CMANGOS_STANDARD_GIT_BRANCH:-$DEFAULT_CMANGOS_STANDARD_GIT_BRANCH}"
CMANGOS_REPO_URL="${CMANGOS_REPO_URL:-$DEFAULT_CMANGOS_REPO_URL}"
CMANGOS_GIT_BRANCH="${CMANGOS_GIT_BRANCH:-$DEFAULT_CMANGOS_GIT_BRANCH}"
CLASSIC_INSTANCE_NAMES=("${CLASSIC_INSTANCE_NAMES[@]:-main}")
TBC_INSTANCE_NAMES=("${TBC_INSTANCE_NAMES[@]:-main}")
TORTOISE_REPO_URL="${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}"
TORTOISE_GIT_BRANCH="${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}"
CRASH_SHARE_ROOT="$CRASH_SHARE_ROOT"

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
VMANGOS_SHARED_REALMD="0"

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
CONFIG_ENV_ENCRYPTION="${CONFIG_ENV_ENCRYPTION:-0}"
if [[ "${CONFIG_ENV_ENCRYPTION}" == "1" ]]; then
  CONFIG_STORAGE_MODE="encrypted"
fi
persist_config_storage

# Keep install-path ordering canonical even if an older config.env exists.
ALLOWED_EXPANSIONS=("classic" "tbc" "wotlk" "vmangos")
LAUNCHER_VERSION="${LAUNCHER_VERSION:-$DEFAULT_LAUNCHER_VERSION}"
CONFIG_ENV_ENCRYPTION="${CONFIG_ENV_ENCRYPTION:-0}"
LAUNCHER_AUTO_UPDATE_ON_START="${LAUNCHER_AUTO_UPDATE_ON_START:-0}"
CRASH_SHARE_ROOT="${CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"
CMANGOS_BUILD_PROFILE="${CMANGOS_BUILD_PROFILE:-repo}"
CMANGOS_STANDARD_REPO_URL="${CMANGOS_STANDARD_REPO_URL:-$DEFAULT_CMANGOS_STANDARD_REPO_URL}"
CMANGOS_STANDARD_GIT_BRANCH="${CMANGOS_STANDARD_GIT_BRANCH:-$DEFAULT_CMANGOS_STANDARD_GIT_BRANCH}"
CMANGOS_REPO_URL="${CMANGOS_REPO_URL:-$DEFAULT_CMANGOS_REPO_URL}"
CMANGOS_GIT_BRANCH="${CMANGOS_GIT_BRANCH:-$DEFAULT_CMANGOS_GIT_BRANCH}"
TORTOISE_REPO_URL="${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}"
TORTOISE_GIT_BRANCH="${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}"
LAUNCHER_GIT_BRANCH="${LAUNCHER_GIT_BRANCH:-unknown}"
LAUNCHER_GIT_COMMIT="${LAUNCHER_GIT_COMMIT:-unknown}"
WEBSITE_GIT_BRANCH="${WEBSITE_GIT_BRANCH:-unknown}"
WEBSITE_GIT_COMMIT="${WEBSITE_GIT_COMMIT:-unknown}"
WEBSITE_GIT_DATE="${WEBSITE_GIT_DATE:-unknown}"
WEBSITE_REMOTE_GIT_BRANCH="${WEBSITE_REMOTE_GIT_BRANCH:-unknown}"
WEBSITE_REMOTE_GIT_COMMIT="${WEBSITE_REMOTE_GIT_COMMIT:-unknown}"
WEBSITE_REMOTE_GIT_DATE="${WEBSITE_REMOTE_GIT_DATE:-unknown}"
WEBSITE_GIT_OUTDATED="${WEBSITE_GIT_OUTDATED:-0}"
refresh_launcher_git_tracking

DB_CTID="${DB_CTID:-}"
WEB_CTID="${WEB_CTID:-}"
LOGIN_CTID="${LOGIN_CTID:-}"
GAME_CTID="${GAME_CTID:-}"
EXPANSION=""

cmangos_build_profile() {
  case "${CMANGOS_BUILD_PROFILE:-repo}" in
    standard|repo) printf '%s' "${CMANGOS_BUILD_PROFILE}" ;;
    *) printf '%s' "repo" ;;
  esac
}

cmangos_build_profile_label() {
  case "$(cmangos_build_profile)" in
    standard) echo "Standard CMaNGOS + playerbots" ;;
    repo) echo "Japtenks CMaNGOS repo + playerbots" ;;
  esac
}

has_cmangos_source_profile() {
  [[ "${1:-$EXPANSION}" == "classic" ]]
}

is_tortoise_profile() {
  [[ "$(cmangos_build_profile)" == "tortoise" ]]
}

cmangos_profile_repo() {
  case "$(cmangos_build_profile)" in
    standard) echo "${CMANGOS_STANDARD_REPO_URL:-$DEFAULT_CMANGOS_STANDARD_REPO_URL}" ;;
    repo) echo "${CMANGOS_REPO_URL:-$DEFAULT_CMANGOS_REPO_URL}" ;;
  esac
}

cmangos_profile_branch() {
  case "$(cmangos_build_profile)" in
    standard) echo "${CMANGOS_STANDARD_GIT_BRANCH:-$DEFAULT_CMANGOS_STANDARD_GIT_BRANCH}" ;;
    repo) echo "${CMANGOS_GIT_BRANCH:-$DEFAULT_CMANGOS_GIT_BRANCH}" ;;
  esac
}

vmangos_instance_name_list() {
  if declare -p VMANGOS_INSTANCE_NAMES >/dev/null 2>&1; then
    printf '%s\n' "${VMANGOS_INSTANCE_NAMES[@]}"
  else
    printf '%s\n' "main" "ahbot"
  fi
}

cmangos_family() {
  case "${1:-$EXPANSION}" in
    classic|classic-*) echo "classic" ;;
    tbc|tbc-*) echo "tbc" ;;
    wotlk) echo "wotlk" ;;
    *) return 1 ;;
  esac
}

is_cmangos_target() {
  case "${1:-$EXPANSION}" in
    classic|classic-*|tbc|tbc-*|wotlk) return 0 ;;
    *) return 1 ;;
  esac
}

cmangos_instance_var_name() {
  case "$1" in
    classic) echo "CLASSIC_INSTANCE_NAMES" ;;
    tbc) echo "TBC_INSTANCE_NAMES" ;;
    *) return 1 ;;
  esac
}

cmangos_instance_name_list() {
  local family="$1"
  local var_name
  var_name=$(cmangos_instance_var_name "$family") || {
    printf '%s\n' "main"
    return 0
  }
  if declare -p "$var_name" >/dev/null 2>&1; then
    local -n names_ref="$var_name"
    printf '%s\n' "${names_ref[@]}"
  else
    printf '%s\n' "main"
  fi
}

cmangos_target_list() {
  local family="$1"
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == "main" ]]; then
      printf '%s\n' "$family"
    else
      printf '%s\n' "${family}-${name}"
    fi
  done < <(cmangos_instance_name_list "$family")
}

cmangos_target_list_all() {
  cmangos_target_list classic
  cmangos_target_list tbc
  printf '%s\n' "wotlk"
}

cmangos_target_suffix() {
  case "${1:-$EXPANSION}" in
    classic|tbc|wotlk) echo "main" ;;
    classic-*) echo "${1#classic-}" ;;
    tbc-*) echo "${1#tbc-}" ;;
    *) echo "" ;;
  esac
}

cmangos_is_main_target() {
  [[ "$(cmangos_target_suffix "${1:-$EXPANSION}")" == "main" ]]
}

cmangos_target_hostname() {
  local target="${1:-$EXPANSION}"
  if cmangos_is_main_target "$target"; then
    echo "spp-$(cmangos_family "$target")"
  else
    echo "spp-${target}"
  fi
}

cmangos_target_display() {
  cmangos_target_hostname "${1:-$EXPANSION}"
}

cmangos_instance_label() {
  local target="${1:-$EXPANSION}"
  local family suffix
  family=$(cmangos_family "$target") || return 1
  suffix=$(cmangos_target_suffix "$target")
  if [[ "$suffix" == "main" ]]; then
    echo "${family^}"
  else
    echo "${family^} ${suffix}"
  fi
}

cmangos_db_token() {
  local target="${1:-$EXPANSION}"
  local family suffix
  family=$(cmangos_family "$target") || return 1
  suffix=$(cmangos_target_suffix "$target")
  if [[ "$suffix" == "main" ]]; then
    printf '%s' "$family"
    return 0
  fi
  suffix=$(echo "$suffix" | tr -cd '[:alnum:]')
  printf '%s%s' "$family" "$suffix"
}

cmangos_next_target() {
  local family="$1"
  local max_suffix=1
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$name" =~ ^[0-9]+$ ]] && (( name > max_suffix )); then
      max_suffix=$name
    fi
  done < <(cmangos_instance_name_list "$family")
  max_suffix=$((max_suffix + 1))
  printf '%s-%s' "$family" "$max_suffix"
}

ensure_cmangos_target_registered() {
  local target="$1"
  local family
  local suffix
  local var_name
  local config_value=""
  family=$(cmangos_family "$target") || return 1
  suffix=$(cmangos_target_suffix "$target")
  [[ "$suffix" == "main" ]] && return 0

  var_name=$(cmangos_instance_var_name "$family") || return 1
  local -n names_ref="$var_name"
  local existing
  for existing in "${names_ref[@]}"; do
    [[ "$existing" == "$suffix" ]] && return 0
  done

  names_ref+=("$suffix")
  local entry
  for entry in "${names_ref[@]}"; do
    if [[ -n "$config_value" ]]; then
      config_value="${config_value} "
    fi
    config_value="${config_value}\"${entry}\""
  done
  config_value="(${config_value})"
  set_or_append_config_line "$var_name" "$config_value"
  persist_config_storage || return 1
}

declare -A VERSION_MAP
for EXP in $(cmangos_target_list_all); do
  KEY=$(cmangos_family "$EXP" | tr '[:lower:]' '[:upper:]')
  for TYPE in WORLD CORE REALM CHARS LOGS MAPS WEBSITE; do
    VAR="${KEY}_${TYPE}_VERSION"
    VERSION_MAP["$EXP:$TYPE"]="${!VAR:-0}"
  done
done
for EXP in vmangos $(while IFS= read -r _name; do printf '%s\n' "vmangos-${_name}"; done < <(vmangos_instance_name_list)); do
  for TYPE in WORLD CORE REALM CHARS LOGS MAPS WEBSITE; do
    VAR="VMANGOS_${TYPE}_VERSION"
    VERSION_MAP["$EXP:$TYPE"]="${!VAR:-0}"
  done
done

vmangos_target_list() {
  local name
  for name in $(vmangos_instance_name_list); do
    printf '%s\n' "vmangos-${name}"
  done
}

vmangos_target_suffix() {
  case "${1:-$EXPANSION}" in
    vmangos) echo "main" ;;
    vmangos-*) echo "${1#vmangos-}" ;;
    *) echo "" ;;
  esac
}

vmangos_is_main_target() {
  [[ "$(vmangos_target_suffix "${1:-$EXPANSION}")" == "main" ]]
}

vmangos_config_token() {
  local suffix
  suffix=$(vmangos_target_suffix "${1:-$EXPANSION}")
  suffix=$(echo "$suffix" | tr '[:lower:]-' '[:upper:]_')
  printf '%s' "$suffix"
}

vmangos_db_token() {
  local suffix
  suffix=$(vmangos_target_suffix "${1:-$EXPANSION}")
  if [[ "$suffix" == "main" ]]; then
    printf 'vmangos'
    return 0
  fi
  suffix=$(echo "$suffix" | tr -cd '[:alnum:]')
  printf 'vmangos%s' "$suffix"
}

vmangos_instance_label() {
  local suffix
  suffix=$(vmangos_target_suffix "${1:-$EXPANSION}")
  if [[ -n "$suffix" ]]; then
    echo "vMaNGOS ${suffix^}"
  else
    echo "vMaNGOS"
  fi
}

vmangos_default_repo() {
  printf '%s' "$DEFAULT_VMANGOS_REPO_URL"
}

vmangos_default_branch() {
  printf '%s' "$DEFAULT_VMANGOS_GIT_BRANCH"
}

vmangos_build_lane_label() {
  local target="${1:-$EXPANSION}"
  local branch
  branch=$(expansion_branch "$target" 2>/dev/null || vmangos_default_branch "$target")
  if [[ "$branch" == "$DEFAULT_VMANGOS_GIT_BRANCH" ]]; then
    echo "default preset"
  else
    echo "custom vMaNGOS pin"
  fi
}

vmangos_repo_var_name() {
  local token
  token=$(vmangos_config_token "${1:-$EXPANSION}")
  if [[ "$token" == "MAIN" ]]; then
    echo "VMANGOS_MAIN_REPO_URL"
  else
    echo "VMANGOS_${token}_REPO_URL"
  fi
}

vmangos_branch_var_name() {
  local token
  token=$(vmangos_config_token "${1:-$EXPANSION}")
  if [[ "$token" == "MAIN" ]]; then
    echo "VMANGOS_MAIN_GIT_BRANCH"
  else
    echo "VMANGOS_${token}_GIT_BRANCH"
  fi
}

vmangos_ip_var_name() {
  local token
  token=$(vmangos_config_token "${1:-$EXPANSION}")
  if [[ "$token" == "MAIN" ]]; then
    echo "IP_VMANGOS"
  else
    echo "IP_VMANGOS_${token}"
  fi
}

vmangos_target_hostname() {
  local target="${1:-$EXPANSION}"
  if [[ "$target" == "vmangos" ]]; then
    echo "spp-vmangos"
  else
    echo "spp-${target}"
  fi
}

vmangos_target_display() {
  local target="${1:-$EXPANSION}"
  echo "$(vmangos_target_hostname "$target")"
}

vmangos_instance_summary() {
  local target
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    printf '%s ' "$target"
  done < <(vmangos_target_list)
}

expansion_title() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk) cmangos_instance_label "$1" ;;
    vmangos|vmangos-*) vmangos_instance_label "$1" ;;
    *) echo "${1^}" ;;
  esac
}

expansion_settings_key() {
  case "$1" in
    classic|classic-*) echo "vanilla" ;;
    tbc|tbc-*|wotlk) cmangos_family "$1" ;;
    vmangos|vmangos-*) echo "vmangos" ;;
    *) return 1 ;;
  esac
}

expansion_install_dir() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk)
      if cmangos_is_main_target "$1"; then
        echo "/srv/mangos-$(cmangos_family "$1")"
      else
        echo "/srv/mangos-$1"
      fi
      ;;
    vmangos|vmangos-*) echo "/srv/vmangos" ;;
    *) return 1 ;;
  esac
}

expansion_repo() {
  local repo_var
  local default_repo
  case "$1" in
    classic|classic-*) cmangos_profile_repo ;;
    tbc|tbc-*) echo "https://github.com/celguar/mangos-tbc.git" ;;
    wotlk) echo "https://github.com/celguar/mangos-wotlk.git" ;;
    vmangos|vmangos-*)
      default_repo=$(vmangos_default_repo "$1")
      repo_var=$(vmangos_repo_var_name "$1")
      echo "${!repo_var:-$default_repo}"
      ;;
    *) return 1 ;;
  esac
}

expansion_branch() {
  local branch_var
  local default_branch
  case "$1" in
    classic|classic-*) cmangos_profile_branch ;;
    tbc|tbc-*|wotlk) echo "ike3-bots" ;;
    vmangos|vmangos-*)
      default_branch=$(vmangos_default_branch "$1")
      branch_var=$(vmangos_branch_var_name "$1")
      echo "${!branch_var:-$default_branch}"
      ;;
    *) return 1 ;;
  esac
}

expansion_realm_db_name() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk) echo "$(cmangos_db_token "$1")realmd" ;;
    vmangos|vmangos-*) echo "$(vmangos_db_token "$1")realmd" ;;
    *) return 1 ;;
  esac
}

expansion_realm_id() {
  local idx=1
  local target
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk)
      for target in $(cmangos_target_list_all); do
        if [[ "$target" == "$1" ]]; then
          echo "$idx"
          return 0
        fi
        idx=$((idx+1))
      done
      return 1
      ;;
    vmangos)
      idx=$((idx + $(cmangos_target_list_all | wc -l)))
      echo "$idx"
      ;;
    vmangos-*)
      idx=$((idx + $(cmangos_target_list_all | wc -l)))
      for target in $(vmangos_target_list); do
        if [[ "$target" == "$1" ]]; then
          echo "$idx"
          return 0
        fi
        idx=$((idx+1))
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

expansion_world_db_name() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk) echo "$(cmangos_db_token "$1")mangos" ;;
    *) return 1 ;;
  esac
}

expansion_char_db_name() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk) echo "$(cmangos_db_token "$1")characters" ;;
    *) return 1 ;;
  esac
}

expansion_armory_db_name() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk) echo "$(cmangos_db_token "$1")armory" ;;
    *) return 1 ;;
  esac
}

expansion_bots_db_name() {
  case "$1" in
    classic|classic-*|tbc|tbc-*|wotlk) echo "$(cmangos_db_token "$1")playerbots" ;;
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
  [[ "${1:-$EXPANSION}" == vmangos* ]]
}

realmd_ctid() {
  if is_vmangos "${1:-$EXPANSION}"; then
    echo "$GAME_CTID"
  else
    echo "$LOGIN_CTID"
  fi
}

is_shared_classic_family() {
  case "${1:-$EXPANSION}" in
    classic|tbc|wotlk) return 0 ;;
    *) return 1 ;;
  esac
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

vmangos_uses_shared_realmd() {
  # vMaNGOS/Turtle-family cores host realmd inside their game LXC.
  return 1
}

owns_realm_install_lane() {
  if vmangos_uses_shared_realmd; then
    is_master
  else
    is_vmangos || [[ -z "${MASTER_EXPANSION:-}" ]] || is_master
  fi
}

realm_version_owner() {
  if vmangos_uses_shared_realmd; then
    echo "${MASTER_EXPANSION:-$EXPANSION}"
  elif is_vmangos; then
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
        vmangos|vmangos-*)
          local vm_ip_var
          vm_ip_var=$(vmangos_ip_var_name "${EXPANSION:-}")
          echo "${!vm_ip_var:-${IP_VMANGOS:-}}"
          ;;
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
  set_config_value "DB_HOST" "$DB_HOST"
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
        libboost-all-dev libace-dev libtbb-dev unzip wget p7zip-full \
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
    vmangos|vmangos-*) DB_KEY="$(vmangos_db_token "$EXPANSION")"; MAP_KEY="vmangos" ;;
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

  if vmangos_uses_shared_realmd; then
    local shared_expansion
    shared_expansion=$(resolve_shared_master_expansion) || {
      echo "Unable to resolve shared realm owner for vMaNGOS shared realmd mode."
      return 1
    }
    REALM_DB_NAME=$(expansion_realm_db_name "$shared_expansion") || return 1
  elif is_vmangos; then
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

resolve_vmangos_db_endpoint() {
  if ! is_vmangos; then
    DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')
    DB_PORT="3306"
    return 0
  fi

  local config_token
  config_token=$(vmangos_config_token "$EXPANSION")
  local host_var="VMANGOS_${config_token}_DB_HOST"
  local port_var="VMANGOS_${config_token}_DB_PORT"
  local host_value="${!host_var:-${VMANGOS_DB_HOST:-}}"
  local port_value="${!port_var:-${VMANGOS_DB_PORT:-3306}}"

  if [[ -n "${host_value:-}" ]]; then
    DB_IP="${host_value}"
    DB_PORT="${port_value}"
    return 0
  fi

  DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')
  DB_PORT="${port_value}"
}

set_config_value() {
  local KEY=$1
  local VALUE=$2
  if grep -q "^${KEY}=" "$CONFIG_FILE"; then
    sed -i "s|^${KEY}=.*|${KEY}=\"${VALUE}\"|" "$CONFIG_FILE"
  else
    printf '%s="%s"\n' "$KEY" "$VALUE" >> "$CONFIG_FILE"
  fi
  persist_config_storage
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
  if vmangos_uses_shared_realmd; then
    :
  elif ! is_shared_classic_family; then
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

  local marker_map_key="${MAP_KEY}"
  if vmangos_uses_shared_realmd; then
    local shared_expansion
    shared_expansion=$(resolve_shared_master_expansion) || return 1
    case "$shared_expansion" in
      classic) marker_map_key="vanilla" ;;
      tbc) marker_map_key="tbc" ;;
      wotlk) marker_map_key="wotlk" ;;
      *) echo "Unknown shared expansion for marker sync: $shared_expansion"; return 1 ;;
    esac
  elif is_vmangos; then
    echo "Skipping realmd_db_version sync for vMaNGOS."
    return 0
  fi

  local SHARED_REALMD_DB="${MASTER_REALMD_DB:-$REALM_DB_NAME}"
  if [[ "$REALM_DB_NAME" != "$SHARED_REALMD_DB" ]]; then
    echo "Keeping dedicated realmd_db_version markers in ${REALM_DB_NAME}."
    return 0
  fi

  local SINGLE_REALMD_SQL="/opt/spp-sql/sql/${marker_map_key}/updates/realmd/5/single_realmd.sql"
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

  # Build the GRANT list — always include this expansion's DBs
  local GRANTS="
    CREATE USER IF NOT EXISTS '${DB_LAN_USER}'@'${DB_LAN_HOST}' IDENTIFIED BY '${DB_LAN_PASS}';
    GRANT ALL PRIVILEGES ON ${WORLD_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
    GRANT ALL PRIVILEGES ON ${CHAR_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
    GRANT ALL PRIVILEGES ON ${LOG_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';
  "

  if ! is_vmangos; then
    local ARMORY_DB
    ARMORY_DB=$(expansion_armory_db_name "$EXPANSION") || return 1
    GRANTS+="GRANT ALL PRIVILEGES ON ${ARMORY_DB}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';"
  fi

  # Always grant realm DB access (shared, owned by master)
  GRANTS+="GRANT ALL PRIVILEGES ON ${REALM_DB_NAME}.* TO '${DB_LAN_USER}'@'${DB_LAN_HOST}';"
  GRANTS+="FLUSH PRIVILEGES;"

  if is_vmangos; then
    resolve_vmangos_db_endpoint || return 1
    pct exec "$GAME_CTID" -- bash -c "
      export MYSQL_PWD='${DB_ROOT_PASS}'
      mariadb --skip-ssl --host='${DB_IP}' --port='${DB_PORT}' --user='root' -e \"${GRANTS}\"
    "
    return $?
  fi

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
  local EXP_BASE="${EXP}"
  if [[ "$EXP_BASE" == vmangos* ]]; then
    EXP_BASE="vmangos"
  fi
  local COLOR LOGO
  local CLEAR="\e[0m"
  local BANNER_VERSION="${LAUNCHER_VERSION:-$DEFAULT_LAUNCHER_VERSION}"
  local BANNER_BRANCH="${LAUNCHER_GIT_BRANCH:-unknown}"
  local BANNER_COMMIT="${LAUNCHER_GIT_COMMIT:-unknown}"
  local WEBSITE_BRANCH="${WEBSITE_GIT_BRANCH:-unknown}"
  local WEBSITE_COMMIT="${WEBSITE_GIT_COMMIT:-unknown}"
  local WEBSITE_DATE="${WEBSITE_GIT_DATE:-unknown}"

  case "$EXP_BASE" in
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
    vmangos)
      COLOR="\e[31m"
      LOGO="
__     ___ __  ___    _   _  ____  ___  ____
\ \   / / |  \/  |   / \ | |/ ___|/ _ \/ ___|
 \ \ / /| | |\/| |  / _ \| | |  _| | | \___ \\
  \ V / | | |  | | / ___ \ | |_| | |_| |___) |
   \_/  |_|_|  |_|/_/   \_\_|\____|\___/|____/
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
  echo "# SPP - $(expansion_title "$EXP")"
  echo "########################################"
  echo -e "$LOGO"
  local RED="\e[31m"
  local RESET="\e[0m"
  local WEB_LINE="SPP-Web Git: ${WEBSITE_GIT_BRANCH}@${WEBSITE_GIT_COMMIT} (${WEBSITE_GIT_DATE})"
  if [[ "${WEBSITE_GIT_OUTDATED:-0}" == "1" ]]; then
    WEB_LINE="${RED}${WEB_LINE} [update available: ${WEBSITE_REMOTE_GIT_BRANCH}@${WEBSITE_REMOTE_GIT_COMMIT} (${WEBSITE_REMOTE_GIT_DATE})]${RESET}"
  fi
  echo "Launcher Git: ${BANNER_BRANCH}@${BANNER_COMMIT}"
  echo -e "$WEB_LINE"
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

  local CORE_RAW WORLD_RAW CHARS_RAW REALM_RAW LOGS_RAW MAPS_RAW
  CORE_RAW=$(grep  '^core:'    <<< "$RAW" | cut -d: -f2-)
  WORLD_RAW=$(grep '^world:'   <<< "$RAW" | cut -d: -f2-)
  CHARS_RAW=$(grep '^chars:'   <<< "$RAW" | cut -d: -f2-)
  REALM_RAW=$(grep '^realm:'   <<< "$RAW" | cut -d: -f2-)
  LOGS_RAW=$(grep  '^logs:'    <<< "$RAW" | cut -d: -f2-)
  MAPS_RAW=$(grep  '^maps:'    <<< "$RAW" | cut -d: -f2-)

  local CORE_VER CORE_BRANCH CORE_COMMIT BOT_BRANCH BOT_COMMIT BUILD_DATE
  IFS='|' read -r CORE_VER CORE_BRANCH CORE_COMMIT BOT_BRANCH BOT_COMMIT BUILD_DATE <<< "$CORE_RAW"

  local WORLD_VER; IFS='|' read -r WORLD_VER _ <<< "$WORLD_RAW"
  local CHARS_VER; IFS='|' read -r CHARS_VER _ <<< "$CHARS_RAW"
  local REALM_VER; IFS='|' read -r REALM_VER _ <<< "$REALM_RAW"
  local LOGS_VER;  IFS='|' read -r LOGS_VER  _ <<< "$LOGS_RAW"
  local MAPS_VER;  IFS='|' read -r MAPS_VER  _ <<< "$MAPS_RAW"

  local GREEN="\e[32m" RED="\e[31m" YELLOW="\e[33m" RESET="\e[0m"
  local EXPECTED_CORE="${VERSION_MAP[$EXPANSION:CORE]:-}"
  local EXPECTED_WORLD="${VERSION_MAP[$EXPANSION:WORLD]:-}"
  local CORE_COLOR WORLD_COLOR
  [[ "$CORE_VER" == "$EXPECTED_CORE" ]] && CORE_COLOR=$GREEN || CORE_COLOR=$RED
  [[ "$WORLD_VER" == "$EXPECTED_WORLD" ]] && WORLD_COLOR=$GREEN || WORLD_COLOR=$RED

  if is_vmangos; then
    echo    "Pinned Repo: $(expansion_repo "$EXPANSION")"
    echo    "Pinned Branch: $(expansion_branch "$EXPANSION")"
  elif has_cmangos_source_profile; then
    echo    "Build Profile: $(cmangos_build_profile_label)"
    echo    "Pinned Repo: $(expansion_repo "$EXPANSION")"
    echo    "Pinned Branch: $(expansion_branch "$EXPANSION")"
  fi
  echo -e "Core: ${CORE_COLOR}v${CORE_VER:-NA}${RESET} (${CORE_BRANCH:-?}@${CORE_COMMIT:-?})"
  echo -e "Bots: ${YELLOW}${BOT_BRANCH:-?}@${BOT_COMMIT:-?}${RESET}"
  echo    "Built: ${BUILD_DATE:-unknown}"
  echo -e "World: ${WORLD_COLOR}${WORLD_VER:-NA}${RESET}"
  echo    "Chars: ${CHARS_VER:-NA}  Realm: ${REALM_VER:-NA}  Maps: ${MAPS_VER:-NA}"
  echo    "Logs: ${LOGS_VER:-NA}"
}


ensure_shared_stack() {

  auto_detect_stack
  local REQUIRE_LOGIN="${1:-auto}"
  if [[ "$REQUIRE_LOGIN" == "auto" ]]; then
    if is_vmangos; then
      REQUIRE_LOGIN="0"
    else
      REQUIRE_LOGIN="1"
    fi
  fi

  if [[ -n "$DB_CTID" && -n "$WEB_CTID" ]]; then
    if [[ "$REQUIRE_LOGIN" != "1" || -n "$LOGIN_CTID" ]]; then
      return
    fi
  fi

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

  if [[ "$REQUIRE_LOGIN" == "1" && -z "$LOGIN_CTID" ]]; then
    read -p "Enter CTID for spp-login: " LOGIN_NEW
    create_container "spp-login" "login" "$LOGIN_NEW" 3
  fi

  auto_detect_stack
  if [[ -z "$DB_CTID" || -z "$WEB_CTID" ]]; then
    echo "Shared DB/web services are still incomplete."
    return 1
  fi
  if [[ "$REQUIRE_LOGIN" == "1" && -z "$LOGIN_CTID" ]]; then
    echo "Shared login service is still incomplete."
    return 1
  fi
}
create_game_container_interactive() {
  auto_detect_stack
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"

  if [[ -n "$GAME_CTID" ]]; then
    echo "Game container $(vmangos_target_display "$EXPANSION") already exists: CTID $GAME_CTID"
    return 0
  fi

  echo
  echo "Create game container for $(expansion_title "$EXPANSION")"
  pct list
  echo

  read -p "Enter new CTID for $(vmangos_target_display "$EXPANSION"): " NEW_CTID
  [[ "$NEW_CTID" =~ ^[0-9]+$ ]] || {
    echo "Invalid CTID."
    return 1
  }

  create_container "$(vmangos_target_hostname "$EXPANSION")" "game" "$NEW_CTID" 4

  auto_detect_stack
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"
  if [[ -z "$GAME_CTID" ]]; then
    echo "Created container was not detected for ${EXPANSION}."
    return 1
  fi
}
ensure_game_container() {

  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"

  if [[ -n "$GAME_CTID" ]]; then
    return
  fi

  echo
  echo "Game container $(vmangos_target_display "$EXPANSION") not found."
  read -p "Create it now? (y/n): " CONFIRM
  [[ "$CONFIRM" != "y" ]] && return 1

  pct list
  echo

  read -p "Enter CTID for $(vmangos_target_display "$EXPANSION"): " NEW_CTID
  [[ ! "$NEW_CTID" =~ ^[0-9]+$ ]] && return 1

  create_container "$(vmangos_target_hostname "$EXPANSION")" "game" "$NEW_CTID" 4

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

require_existing_game_container() {
  ensure_expansion_context || return 1
  auto_detect_stack
  GAME_CTID="${GAME_CTIDS[$EXPANSION]:-}"

  if [[ -n "$GAME_CTID" ]]; then
    return 0
  fi

  echo
  echo "Game container $(vmangos_target_display "$EXPANSION") is not installed."
  echo "Open Stack Control when you are ready to create or attach that container."
  return 1
}

#menus and functions

main() {

  while true; do
  
    expansion_menu
    service_menu
  done
}

vmangos_instance_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Choose vMaNGOS Instance:"
    echo

    local options=()
    local target
    while IFS= read -r target; do
      [[ -n "$target" ]] && options+=("$target")
    done < <(vmangos_target_list)

    local i
    for i in "${!options[@]}"; do
      target="${options[$i]}"
      local ctid="${GAME_CTIDS[$target]:-}"
      local status=$([[ -n "$ctid" ]] && echo "[Installed - CTID $ctid]" || echo "[Not Installed]")
      echo "$((i+1)) - $(expansion_title "$target")"
      echo "       [Container: $(vmangos_target_display "$target")]"
      echo "       $status"
      echo
    done

    echo "0 - Back"
    echo

    read -p "Selection: " VMSEL
    VMSEL="${VMSEL:-}"
    [[ "$VMSEL" == "0" ]] && return 1

    local index=$((VMSEL-1))
    if [[ $index -ge 0 && $index -lt ${#options[@]} ]]; then
      EXPANSION="${options[$index]}"
      return 0
    fi
  done
}

show_tortoise_wip_notice() {
  echo
  echo "Tortoise/Turtle WoW belongs in the vMaNGOS-family install lane."
  echo "The build should be wired like vMaNGOS, but its SQL/data/config install path is not proven yet."
  echo "It should share the MariaDB container and host realmd in its own game LXC."
  echo "Upstream currently targets Turtle client 1.18.1 build 7272, recommends Ubuntu 22.04-class Linux builds, and adds ACE to the usual MaNGOS dependency set."
  echo
  echo "Planned source default:"
  echo "  Repo: ${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}"
  echo "  Branch: ${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}"
  echo
  echo "Next work item: add tortoise as a real LXC target with upstream-style DB bootstrap and Docker-based data extraction."
  read -p "Press Enter to continue..." _
}

vmangos_register_instance_name() {
  local requested_name="$1"
  local normalized
  normalized=$(echo "$requested_name" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-' | sed 's/^-//; s/-$//')
  [[ -n "$normalized" ]] || return 1

  local current_name
  while IFS= read -r current_name; do
    [[ "$current_name" == "$normalized" ]] && {
      printf '%s' "vmangos-${normalized}"
      return 0
    }
  done < <(vmangos_instance_name_list)

  VMANGOS_INSTANCE_NAMES+=("$normalized")

  local config_value=""
  local entry
  for entry in "${VMANGOS_INSTANCE_NAMES[@]}"; do
    if [[ -n "$config_value" ]]; then
      config_value="${config_value} "
    fi
    config_value="${config_value}\"${entry}\""
  done
  config_value="(${config_value})"

  set_or_append_config_line "VMANGOS_INSTANCE_NAMES" "$config_value"
  persist_config_storage || return 1
  auto_detect_stack
  printf '%s' "vmangos-${normalized}"
}

install_new_cmangos_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Install New - CMaNGOS"
    echo "Classic/TBC lanes. Classic can use stock or repo/module build profiles."
    echo

    local options=()
    local exp
    for exp in classic tbc; do
      if [[ -z "${GAME_CTIDS[$exp]:-}" ]]; then
        options+=("$exp")
      fi
    done

    if [[ ${#options[@]} -eq 0 ]]; then
      echo "No uninstalled CMaNGOS lanes are available."
      echo
      echo "Installed CMaNGOS lanes:"
      for exp in classic tbc; do
        if [[ -n "${GAME_CTIDS[$exp]:-}" ]]; then
          echo "  - $(expansion_title "$exp") [CTID ${GAME_CTIDS[$exp]}]"
        fi
      done
      echo
      echo "Use the main launcher menu to select an installed lane, then run:"
      echo "  Maintenance -> I - Full (re)Install"
      echo
      read -p "Press Enter to return..." _
      return 1
    fi

    local i opt title
    for i in "${!options[@]}"; do
      opt="${options[$i]}"
      title="$(expansion_title "$opt")"
      echo "$((i+1)) - $title"
      echo "       [Install Path: $opt]"
      echo "       [Not Installed]"
      echo
    done

    echo "0 - Back"
    echo
    read -p "Selection: " NEWSEL
    NEWSEL="${NEWSEL:-}"
    [[ "$NEWSEL" == "0" ]] && return 1

    [[ "$NEWSEL" =~ ^[0-9]+$ ]] || continue
    local index=$((NEWSEL-1))
    if [[ $index -ge 0 && $index -lt ${#options[@]} ]]; then
      EXPANSION="${options[$index]}"
      return 0
    fi
  done
}

install_new_vmangos_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Install New - vMaNGOS"
    echo "Classic uses the configured vMaNGOS bot build. Tortoise/Turtle is experimental."
    echo

    local options=()
    local target
    while IFS= read -r target; do
      [[ -n "$target" ]] || continue
      if [[ -z "${GAME_CTIDS[$target]:-}" ]]; then
        options+=("$target")
      fi
    done < <(vmangos_target_list)
    options+=("tortoise")

    local i opt title
    for i in "${!options[@]}"; do
      opt="${options[$i]}"
      if [[ "$opt" == "tortoise" ]]; then
        title="Tortoise/Turtle WoW [Experimental - installer TBD]"
      else
        title="$(expansion_title "$opt")"
      fi
      echo "$((i+1)) - $title"
      echo "       [Install Path: $opt]"
      if [[ "$opt" == "tortoise" ]]; then
        echo "       [Not Installed - DB/data flow unproven]"
      else
        echo "       [Not Installed]"
      fi
      echo
    done

    echo "N - New vMaNGOS instance"
    echo "0 - Back"
    echo
    read -p "Selection: " VMNEWSEL
    VMNEWSEL="${VMNEWSEL:-}"
    [[ "$VMNEWSEL" == "0" ]] && return 1

    if [[ "$VMNEWSEL" =~ ^[Nn]$ ]]; then
      local new_instance_name new_target
      echo
      echo "Enter a new vMaNGOS instance name. Example: ahbot2 or test."
      read -p "Instance name: " new_instance_name
      new_target=$(vmangos_register_instance_name "$new_instance_name") || {
        echo "Unable to register that vMaNGOS instance name."
        read -p "Press Enter to continue..." _
        continue
      }
      EXPANSION="$new_target"
      return 0
    fi

    [[ "$VMNEWSEL" =~ ^[0-9]+$ ]] || continue
    local index=$((VMNEWSEL-1))
    if [[ $index -ge 0 && $index -lt ${#options[@]} ]]; then
      if [[ "${options[$index]}" == "tortoise" ]]; then
        local tortoise_target
        tortoise_target=$(vmangos_register_instance_name "tortoise") || {
          echo "Unable to register the tortoise instance."
          read -p "Press Enter to continue..." _
          continue
        }
        EXPANSION="$tortoise_target"
        vmangos_persist_source_pin "$EXPANSION" "${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}" "${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}" || {
          echo "Unable to pin the default tortoise source."
          read -p "Press Enter to continue..." _
          continue
        }
        return 0
      fi
      EXPANSION="${options[$index]}"
      return 0
    fi
  done
}

install_new_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Install New"
    echo
    echo "1 - CMaNGOS (Classic, TBC)"
    echo "2 - vMaNGOS (Classic, Tortoise)"
    echo "0 - Back"
    echo

    read -p "Selection: " FAMILY_SEL
    FAMILY_SEL="${FAMILY_SEL:-}"

    case "$FAMILY_SEL" in
      1)
        if install_new_cmangos_menu; then
          ensure_expansion_context || continue
          ensure_game_container || continue
          return
        fi
        ;;
      2)
        if install_new_vmangos_menu; then
          ensure_expansion_context || continue
          ensure_game_container || continue
          return
        fi
        ;;
      0) return 1 ;;
    esac
  done
}

expansion_menu() {
  while true; do
    clear
    print_banner
    auto_detect_stack

    echo "Choose Install Path:"
    echo

    local options=()
    local exp target
    for exp in classic tbc; do
      [[ -n "${GAME_CTIDS[$exp]:-}" ]] && options+=("$exp")
    done
    local vm_installed=()
    while IFS= read -r target; do
      [[ -n "${GAME_CTIDS[$target]:-}" ]] && vm_installed+=("$target")
    done < <(vmangos_target_list)
    if [[ ${#vm_installed[@]} -gt 0 ]]; then
      options+=("vmangos")
    fi

    local i
    for i in "${!options[@]}"; do
      EXP="${options[$i]}"
      if [[ "$EXP" == "vmangos" ]]; then
        STATUS="[${#vm_installed[@]} instance(s) installed]"
      else
        CTID="${GAME_CTIDS[$EXP]:-}"
        STATUS="[Installed - CTID $CTID]"
      fi
      TITLE="$(expansion_title "$EXP")"
      if [[ "$EXP" == "vmangos" ]]; then
        if vmangos_uses_shared_realmd "$EXP"; then
          TITLE="${TITLE} [Shared realmd]"
        else
          TITLE="${TITLE} [Dedicated Realm DB]"
        fi
      fi
      echo "$((i+1)) - $TITLE"
      echo "       [Install Path: $EXP]"
      echo "       $STATUS"
      echo
    done

    echo "M - Shared Services"
    echo "I - Install New"
    echo "0 - Exit"
    echo

    read -p "Selection: " SEL
    SEL="${SEL:-}"

    [[ "$SEL" == "0" ]] && exit_launcher_cleanly

    if [[ "$SEL" =~ ^[Mm]$ ]]; then
      shared_services_menu
      continue
    fi
    if [[ "$SEL" =~ ^[Ii]$ ]]; then
      install_new_menu && return
      continue
    fi

    [[ "$SEL" =~ ^[0-9]+$ ]] || continue
    INDEX=$((SEL-1))
    if [[ $INDEX -ge 0 && $INDEX -lt ${#options[@]} ]]; then
      if [[ "${options[$INDEX]}" == "vmangos" ]]; then
        vmangos_instance_menu && return
        continue
      fi
      EXPANSION="${options[$INDEX]}"
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
    echo "MariaDB and website are shared across all lanes."
    echo "Classic/TBC/WotLK use the shared login container. vMaNGOS/Turtle host realmd in their game LXC."
    echo
    echo "1 - Status"
    echo "2 - Service Control"
    echo "3 - Website"
    echo "4 - Repo"
    echo "5 - Configuration"
    echo "6 - Update Launcher"
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
      6) update_launcher_self ;;
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
  echo "7 - Config encryption: (${CONFIG_ENV_ENCRYPTION})"
  echo "8 - Crash share root: (${CRASH_SHARE_ROOT})"
  echo "0 - Back"

  read -p "Selection: " C

  case "$C" in
    1) run_with_shared_classic_context update_db_conf ;;
    2) run_with_shared_classic_context fix_realm_entry ;;
    3) run_with_shared_classic_context service_create ;;
	4) run_with_shared_classic_context deploy_realmd ;;
	5) run_with_shared_classic_context deploy_spp_configs ;;
	6) fix_mariadb_bind ;;
    7) toggle_config_encryption ;;
    8) edit_crash_share_root ;;
  esac
}

toggle_config_encryption() {
  echo
  if [[ "${CONFIG_ENV_ENCRYPTION:-0}" == "1" ]]; then
    echo "Config encryption is currently ENABLED."
    read -p "Disable encryption and write plaintext config.env on disk? (YES): " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || return

    CONFIG_ENV_ENCRYPTION="0"
    CONFIG_STORAGE_MODE="plain"
    set_or_append_config_line "CONFIG_ENV_ENCRYPTION" "\"0\""
    persist_config_storage || {
      CONFIG_ENV_ENCRYPTION="1"
      CONFIG_STORAGE_MODE="encrypted"
      set_or_append_config_line "CONFIG_ENV_ENCRYPTION" "\"1\""
      echo "Failed to disable config encryption."
      read -p "Press Enter to continue..." _
      return 1
    }

    echo "Config encryption disabled. Settings are now stored in config.env."
  else
    command -v openssl >/dev/null 2>&1 || {
      echo "OpenSSL is required to enable config encryption."
      read -p "Press Enter to continue..." _
      return 1
    }

    echo "Config encryption is currently DISABLED."
    read -p "Enable encrypted config storage? (YES): " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || return

    prompt_config_passphrase "new" || {
      read -p "Press Enter to continue..." _
      return 1
    }

    CONFIG_ENV_ENCRYPTION="1"
    CONFIG_STORAGE_MODE="encrypted"
    set_or_append_config_line "CONFIG_ENV_ENCRYPTION" "\"1\""
    persist_config_storage || {
      CONFIG_ENV_ENCRYPTION="0"
      CONFIG_STORAGE_MODE="plain"
      set_or_append_config_line "CONFIG_ENV_ENCRYPTION" "\"0\""
      echo "Failed to enable config encryption."
      read -p "Press Enter to continue..." _
      return 1
    }

    echo "Config encryption enabled. Settings are now stored in config.env.enc."
  fi

  read -p "Press Enter to continue..." _
}

edit_crash_share_root() {
  echo
  echo "Current crash share root: ${CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"
  read -p "New default crash share root on Proxmox host [$DEFAULT_CRASH_SHARE_ROOT]: " NEW_CRASH_SHARE_ROOT
  NEW_CRASH_SHARE_ROOT="${NEW_CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"
  CRASH_SHARE_ROOT="$NEW_CRASH_SHARE_ROOT"
  set_or_append_config_line "CRASH_SHARE_ROOT" "\"${CRASH_SHARE_ROOT}\""
  persist_config_storage || {
    echo "Failed to save crash share root."
    read -p "Press Enter to continue..." _
    return 1
  }
  echo "Crash share root saved as: ${CRASH_SHARE_ROOT}"
  read -p "Press Enter to continue..." _
}

edit_operator_sources() {
  local new_repo new_profile new_std_repo new_std_branch new_cm_repo new_cm_branch
  local new_vm_repo new_vm_branch new_world_url new_pack_url

  echo
  echo "Operator-owned source settings"
  echo "Leave blank to keep the current value."
  echo
  echo "Website repo: ${WEBSITE_REPO:-<unset>}"
  echo "CMaNGOS build profile: $(cmangos_build_profile) ($(cmangos_build_profile_label))"
  echo "CMaNGOS standard repo: ${CMANGOS_STANDARD_REPO_URL:-<unset>}"
  echo "CMaNGOS standard branch: ${CMANGOS_STANDARD_GIT_BRANCH:-<unset>}"
  echo "CMaNGOS repo lane repo: ${CMANGOS_REPO_URL:-<unset>}"
  echo "CMaNGOS repo lane branch: ${CMANGOS_GIT_BRANCH:-<unset>}"
  echo "vMaNGOS repo: ${VMANGOS_REPO_URL:-<unset>}"
  echo "vMaNGOS branch: ${VMANGOS_GIT_BRANCH:-<unset>}"
  echo "vMaNGOS world DB URL: ${VMANGOS_WORLD_DB_URL:-<unset>}"
  echo "vMaNGOS data pack URL: ${VMANGOS_DATA_PACK_URL:-<unset>}"
  echo

  read -p "Website repo [${WEBSITE_REPO:-}]: " new_repo
  read -p "CMaNGOS build profile (standard/repo) [$(cmangos_build_profile)]: " new_profile
  read -p "CMaNGOS standard repo [${CMANGOS_STANDARD_REPO_URL:-}]: " new_std_repo
  read -p "CMaNGOS standard branch [${CMANGOS_STANDARD_GIT_BRANCH:-}]: " new_std_branch
  read -p "CMaNGOS repo lane repo [${CMANGOS_REPO_URL:-}]: " new_cm_repo
  read -p "CMaNGOS repo lane branch [${CMANGOS_GIT_BRANCH:-}]: " new_cm_branch
  read -p "vMaNGOS repo [${VMANGOS_REPO_URL:-}]: " new_vm_repo
  read -p "vMaNGOS branch [${VMANGOS_GIT_BRANCH:-}]: " new_vm_branch
  read -p "vMaNGOS world DB URL [${VMANGOS_WORLD_DB_URL:-}]: " new_world_url
  read -p "vMaNGOS data pack URL [${VMANGOS_DATA_PACK_URL:-}]: " new_pack_url

  if [[ -n "$new_repo" ]]; then
    WEBSITE_REPO="$new_repo"
    set_config_value "WEBSITE_REPO" "$new_repo"
  fi
  if [[ -n "$new_profile" ]]; then
    case "$new_profile" in
      standard|repo)
        CMANGOS_BUILD_PROFILE="$new_profile"
        set_config_value "CMANGOS_BUILD_PROFILE" "$new_profile"
        ;;
      *) echo "Ignoring unknown CMaNGOS build profile: $new_profile" ;;
    esac
  fi
  [[ -n "$new_std_repo" ]] && { CMANGOS_STANDARD_REPO_URL="$new_std_repo"; set_config_value "CMANGOS_STANDARD_REPO_URL" "$new_std_repo"; }
  [[ -n "$new_std_branch" ]] && { CMANGOS_STANDARD_GIT_BRANCH="$new_std_branch"; set_config_value "CMANGOS_STANDARD_GIT_BRANCH" "$new_std_branch"; }
  [[ -n "$new_cm_repo" ]] && { CMANGOS_REPO_URL="$new_cm_repo"; set_config_value "CMANGOS_REPO_URL" "$new_cm_repo"; }
  [[ -n "$new_cm_branch" ]] && { CMANGOS_GIT_BRANCH="$new_cm_branch"; set_config_value "CMANGOS_GIT_BRANCH" "$new_cm_branch"; }
  [[ -n "$new_vm_repo" ]] && { VMANGOS_REPO_URL="$new_vm_repo"; set_config_value "VMANGOS_REPO_URL" "$new_vm_repo"; }
  [[ -n "$new_vm_branch" ]] && { VMANGOS_GIT_BRANCH="$new_vm_branch"; set_config_value "VMANGOS_GIT_BRANCH" "$new_vm_branch"; }
  [[ -n "$new_world_url" ]] && { VMANGOS_WORLD_DB_URL="$new_world_url"; set_config_value "VMANGOS_WORLD_DB_URL" "$new_world_url"; }
  [[ -n "$new_pack_url" ]] && { VMANGOS_DATA_PACK_URL="$new_pack_url"; set_config_value "VMANGOS_DATA_PACK_URL" "$new_pack_url"; }

  WEBSITE_REPO="${WEBSITE_REPO:-$DEFAULT_WEBSITE_REPO}"
  CMANGOS_BUILD_PROFILE="${CMANGOS_BUILD_PROFILE:-repo}"
  CMANGOS_STANDARD_REPO_URL="${CMANGOS_STANDARD_REPO_URL:-$DEFAULT_CMANGOS_STANDARD_REPO_URL}"
  CMANGOS_STANDARD_GIT_BRANCH="${CMANGOS_STANDARD_GIT_BRANCH:-$DEFAULT_CMANGOS_STANDARD_GIT_BRANCH}"
  CMANGOS_REPO_URL="${CMANGOS_REPO_URL:-$DEFAULT_CMANGOS_REPO_URL}"
  CMANGOS_GIT_BRANCH="${CMANGOS_GIT_BRANCH:-$DEFAULT_CMANGOS_GIT_BRANCH}"
  TORTOISE_REPO_URL="${TORTOISE_REPO_URL:-$DEFAULT_TORTOISE_REPO_URL}"
  TORTOISE_GIT_BRANCH="${TORTOISE_GIT_BRANCH:-$DEFAULT_TORTOISE_GIT_BRANCH}"
  VMANGOS_REPO_URL="${VMANGOS_REPO_URL:-$DEFAULT_VMANGOS_REPO_URL}"
  VMANGOS_GIT_BRANCH="${VMANGOS_GIT_BRANCH:-$DEFAULT_VMANGOS_GIT_BRANCH}"

  echo "Operator-owned source settings saved."
  read -p "Press Enter to continue..." _
}

edit_cmangos_source_profile() {
  local current_profile new_profile
  local repo_var branch_var current_repo current_branch new_repo new_branch
  current_profile="$(cmangos_build_profile)"

  echo
  echo "CMaNGOS build profile"
  echo "1 - standard  Standard CMaNGOS + playerbots"
  echo "2 - repo      Japtenks CMaNGOS repo + playerbots"
  echo
  echo "Current profile: ${current_profile} ($(cmangos_build_profile_label))"
  read -p "Profile [${current_profile}]: " new_profile

  case "${new_profile:-$current_profile}" in
    1|standard) new_profile="standard"; repo_var="CMANGOS_STANDARD_REPO_URL"; branch_var="CMANGOS_STANDARD_GIT_BRANCH" ;;
    2|repo) new_profile="repo"; repo_var="CMANGOS_REPO_URL"; branch_var="CMANGOS_GIT_BRANCH" ;;
    *)
      echo "Unknown CMaNGOS build profile."
      read -p "Press Enter to continue..." _
      return 1
      ;;
  esac

  set_config_value "CMANGOS_BUILD_PROFILE" "$new_profile"
  CMANGOS_BUILD_PROFILE="$new_profile"
  current_repo="${!repo_var:-}"
  current_branch="${!branch_var:-}"
  echo
  echo "Leave repo/branch blank to keep the current pin."
  read -p "Repo [${current_repo}]: " new_repo
  read -p "Branch [${current_branch}]: " new_branch
  if [[ -n "$new_repo" ]]; then
    printf -v "$repo_var" '%s' "$new_repo"
    set_config_value "$repo_var" "$new_repo"
  fi
  if [[ -n "$new_branch" ]]; then
    printf -v "$branch_var" '%s' "$new_branch"
    set_config_value "$branch_var" "$new_branch"
  fi

  echo
  echo "Saved CMaNGOS profile: $(cmangos_build_profile) ($(cmangos_build_profile_label))"
  echo "Repo: $(expansion_repo classic)"
  echo "Branch: $(expansion_branch classic)"
  read -p "Press Enter to continue..." _
}

edit_vmangos_instance_names() {
  local current_names=""
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -n "$current_names" ]]; then
      current_names="${current_names} ${name}"
    else
      current_names="$name"
    fi
  done < <(vmangos_instance_name_list)

  echo
  echo "Current vMaNGOS instance names:"
  echo "  ${current_names}"
  echo
  echo "Enter space-separated names. Example: main ahbot"
  echo "The first-class target names become vmangos-<name>."
  echo "The 'main' instance is required so existing vmangos installs still map cleanly."
  echo

  local raw_names
  read -p "Instance names [${current_names}]: " raw_names
  raw_names="${raw_names:-$current_names}"

  local -a sanitized=()
  local token cleaned
  for token in $raw_names; do
    cleaned=$(echo "$token" | tr '[:upper:]' '[:lower:]' | tr ' _' '--' | tr -cd 'a-z0-9-')
    cleaned="${cleaned#-}"
    cleaned="${cleaned%-}"
    [[ -n "$cleaned" ]] || continue
    if [[ ! " ${sanitized[*]} " =~ [[:space:]]${cleaned}[[:space:]] ]]; then
      sanitized+=("$cleaned")
    fi
  done

  if [[ ${#sanitized[@]} -eq 0 ]]; then
    echo "No valid names provided."
    read -p "Press Enter to continue..." _
    return 1
  fi

  if [[ ! " ${sanitized[*]} " =~ [[:space:]]main[[:space:]] ]]; then
    sanitized=("main" "${sanitized[@]}")
  fi

  local config_value="("
  local idx
  for idx in "${!sanitized[@]}"; do
    [[ $idx -gt 0 ]] && config_value+=" "
    config_value+="\"${sanitized[$idx]}\""
  done
  config_value+=")"

  VMANGOS_INSTANCE_NAMES=("${sanitized[@]}")
  set_or_append_config_line "VMANGOS_INSTANCE_NAMES" "$config_value"

  persist_config_storage || {
    echo "Failed to save vMaNGOS instance names."
    read -p "Press Enter to continue..." _
    return 1
  }

  auto_detect_stack

  echo
  echo "Saved vMaNGOS instance names:"
  printf '  %s\n' "${VMANGOS_INSTANCE_NAMES[@]}"
  read -p "Press Enter to continue..." _
}

edit_vmangos_source_pin() {
  local DEFAULT_REPO
  local DEFAULT_BRANCH
  DEFAULT_REPO=$(vmangos_default_repo "$EXPANSION")
  DEFAULT_BRANCH=$(vmangos_default_branch "$EXPANSION")

  local REPO_VAR
  local BRANCH_VAR
  REPO_VAR=$(vmangos_repo_var_name "$EXPANSION")
  BRANCH_VAR=$(vmangos_branch_var_name "$EXPANSION")
  local CURRENT_REPO
  local CURRENT_BRANCH
  CURRENT_REPO=$(expansion_repo "$EXPANSION")
  CURRENT_BRANCH=$(expansion_branch "$EXPANSION")
  local NEW_REPO NEW_BRANCH

  echo
  echo "Current $(expansion_title "$EXPANSION") source pin:"
  echo "  Layer: $(vmangos_build_lane_label "$EXPANSION")"
  echo "  Repo: ${CURRENT_REPO}"
  echo "  Branch: ${CURRENT_BRANCH}"
  echo
  echo "Leave a field blank to keep the current value."
  echo "Type DEFAULT to reset a field to the launcher default."
  echo

  read -p "Pinned repo [${CURRENT_REPO}]: " NEW_REPO
  read -p "Pinned branch [${CURRENT_BRANCH}]: " NEW_BRANCH

  if [[ "${NEW_REPO}" == "DEFAULT" ]]; then
    NEW_REPO="$DEFAULT_REPO"
  elif [[ -z "${NEW_REPO}" ]]; then
    NEW_REPO="$CURRENT_REPO"
  fi

  if [[ "${NEW_BRANCH}" == "DEFAULT" ]]; then
    NEW_BRANCH="$DEFAULT_BRANCH"
  elif [[ -z "${NEW_BRANCH}" ]]; then
    NEW_BRANCH="$CURRENT_BRANCH"
  fi

  printf -v "$REPO_VAR" '%s' "$NEW_REPO"
  printf -v "$BRANCH_VAR" '%s' "$NEW_BRANCH"

  set_or_append_config_line "$REPO_VAR" "\"${!REPO_VAR}\""
  set_or_append_config_line "$BRANCH_VAR" "\"${!BRANCH_VAR}\""
  if vmangos_is_main_target "$EXPANSION"; then
    VMANGOS_REPO_URL="${!REPO_VAR}"
    VMANGOS_GIT_BRANCH="${!BRANCH_VAR}"
    set_or_append_config_line "VMANGOS_REPO_URL" "\"${VMANGOS_REPO_URL}\""
    set_or_append_config_line "VMANGOS_GIT_BRANCH" "\"${VMANGOS_GIT_BRANCH}\""
  fi

  persist_config_storage || {
    echo "Failed to save $(expansion_title "$EXPANSION") source pin."
    read -p "Press Enter to continue..." _
    return 1
  }

  echo
  echo "Saved $(expansion_title "$EXPANSION") source pin:"
  echo "  Repo: ${!REPO_VAR}"
  echo "  Branch: ${!BRANCH_VAR}"
  read -p "Press Enter to continue..." _
}

update_db_conf() {
  derive_db_names || return 1
  local TARGET_EXPANSION="${1:-$EXPANSION}"
  local CONFIG_EXPANSIONS=("$TARGET_EXPANSION")
  local SAVED_EXPANSION="$EXPANSION"
  local SAVED_GAME_CTID="${GAME_CTID:-}"

  if is_vmangos "$TARGET_EXPANSION"; then
    EXPANSION="$TARGET_EXPANSION"
    GAME_CTID="${GAME_CTIDS[$EXPANSION]:-${GAME_CTID:-}}"
    derive_db_names || return 1
    resolve_vmangos_db_endpoint || return 1
  else
    DB_IP=$(pct exec "$DB_CTID" -- hostname -I | awk '{print $1}')
    DB_PORT="3306"
  fi

  if is_vmangos "$TARGET_EXPANSION"; then
    if pct exec "$GAME_CTID" -- test -f "${INSTALL_DIR}/etc/realmd.conf" 2>/dev/null; then
      pct exec "$GAME_CTID" -- bash -c "
        sed -i \
        's|^LoginDatabase\.Info *=.*|LoginDatabase.Info              = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
        ${INSTALL_DIR}/etc/realmd.conf
      "
      echo "$TARGET_EXPANSION realmd.conf updated in game container."
    else
      echo "$TARGET_EXPANSION realmd.conf missing in game container; build/config install must create it first."
    fi
  else
    MASTER_EXPANSION=$(resolve_shared_master_expansion) || {
    echo "No shared Classic/TBC/WotLK master expansion is available yet."
    EXPANSION="$SAVED_EXPANSION"
    GAME_CTID="$SAVED_GAME_CTID"
    return 1
    }

  MASTER_INSTALL_DIR=$(expansion_install_dir "$MASTER_EXPANSION") || return 1

  if pct exec "$LOGIN_CTID" -- test -f "${MASTER_INSTALL_DIR}/etc/realmd.conf" 2>/dev/null; then
    pct exec "$LOGIN_CTID" -- bash -c "
      sed -i \
      's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
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
      's|^LoginDatabaseInfo *=.*|LoginDatabaseInfo = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
      ${MASTER_INSTALL_DIR}/etc/realmd.conf
    "
    echo "realmd.conf updated."
  fi

  # mangosd.conf — only update the expansion currently being installed/updated
  fi

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
      if [[ '$EXP' == vmangos* ]]; then
        sed -i \
        -e 's|^RealmID *=.*|RealmID = ${REALM_ID}|' \
        -e 's|^LoginDatabase\.Info *=.*|LoginDatabase.Info              = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${REALM_DB_NAME}\"|' \
        -e 's|^WorldDatabase\.Info *=.*|WorldDatabase.Info              = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${WORLD_DB}\"|' \
        -e 's|^CharacterDatabase\.Info *=.*|CharacterDatabase.Info          = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${CHAR_DB_NAME}\"|' \
        -e 's|^LogsDatabase\.Info *=.*|LogsDatabase.Info               = \"${DB_IP};${DB_PORT};${DB_LAN_USER};${DB_LAN_PASS};${LOG_DB_NAME}\"|' \
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

  EXPANSION="$SAVED_EXPANSION"
  GAME_CTID="$SAVED_GAME_CTID"
}

service_create() {
  ensure_expansion_context || return 1
  derive_db_names || return 1
  local REALMD_CTID=""
  local WRITE_REALMD=0

  # CMaNGOS uses the shared login LXC; vMaNGOS-family cores host realmd beside mangosd.
  if is_vmangos; then
    REALMD_CTID="$GAME_CTID"
    WRITE_REALMD=1
  elif is_master; then
    REALMD_CTID="$LOGIN_CTID"
    WRITE_REALMD=1
  fi

  if (( WRITE_REALMD )); then
    pct exec "$REALMD_CTID" -- bash -c "
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
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
"
    pct exec "$REALMD_CTID" -- systemctl daemon-reload
    echo "realmd service written in CT $REALMD_CTID."
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
ExecStartPre=/bin/bash -lc 'cd $INSTALL_DIR/bin && ls -1t core.* 2>/dev/null | tail -n +4 | xargs -r rm -f'
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

  LOGIN_IP=$(pct exec "$(realmd_ctid)" -- hostname -I | awk '{print $1}')

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
  refresh_website_git_tracking
  refresh_website_remote_git_tracking

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
  refresh_website_git_tracking
  refresh_website_remote_git_tracking
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
    if [[ -n "${EXPANSION:-}" ]]; then
      echo "Current Install Path: $(expansion_title "$EXPANSION") [${EXPANSION}]"
    else
      echo "Current Install Path: none"
    fi
    if is_vmangos; then
      echo "Build Lane: $(vmangos_build_lane_label "$EXPANSION")"
      echo "Pinned vMaNGOS Repo: $(expansion_repo "$EXPANSION")"
      echo "Pinned vMaNGOS Branch: $(expansion_branch "$EXPANSION")"
    elif has_cmangos_source_profile; then
      echo "Build Lane: $(cmangos_build_profile_label)"
      echo "Pinned CMaNGOS Repo: $(expansion_repo "$EXPANSION")"
      echo "Pinned CMaNGOS Branch: $(expansion_branch "$EXPANSION")"
    fi
    echo "1 - Stack Control"
    echo "2 - Maintenance"
    echo "3 - Select Install Path"
    echo
    echo "4 - Remote Console"
    echo "5 - Live World Log"
    echo
    echo "6 - Autostart Status: ($ASV)"
	echo "7 - Server Info"
    echo "0 - Back to Launcher"
    echo

    read -p "Selection: " MAIN

    case "$MAIN" in
      1) ensure_service_target_context && stack_control_menu ;;
      2) ensure_expansion_context && maintenance_menu ;;
      3) expansion_menu ;;
      4) ensure_service_target_context && connect_ra ;;
      5) ensure_service_target_context && live_logs ;;
      6) ensure_service_target_context && toggle_autostart ;;
	  7) ensure_service_target_context && server_info_menu ;;
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
  trap 'mark_launcher_unclean_exit; echo; echo "Returning to menu..."; return' INT
  pct exec "$GAME_CTID" -- tail -f /var/log/mangos/Server.log
  trap 'handle_launcher_interrupt INT' INT
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
  set_config_value "AUTO_START" "$AUTO_START"
  set_config_value "ASV" "$ASV"
  apply_autostart_setting

  echo "AUTO_START is now: $AUTO_START"
}
apply_autostart_setting() {
[[ -z "$LOGIN_CTID" ]] && auto_detect_stack
  local REALMD_CTID
  REALMD_CTID=$(realmd_ctid)
  if [[ "$AUTO_START" == "1" ]]; then
    pct exec "$REALMD_CTID" -- systemctl enable realmd
    pct exec "$GAME_CTID" -- systemctl enable mangosd
	pct exec "$REALMD_CTID" -- systemctl start realmd
    start_mangosd_managed "autostart-enable"
    echo "Autostart ENABLED"
  else
    pct exec "$REALMD_CTID" -- systemctl disable realmd
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
      3)
        if ! ensure_service_target_context; then
          read -p "Unable to continue. Press Enter to return..." _
        elif ! install_data; then
          read -p "Data pack install failed. Press Enter to return..." _
        fi
        ;;
	  4) config_menu ;;
      I)
        read -p "Type YES to continue: " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && ensure_service_target_context && full_install
        ;;
	  S) 	 
        read -p "Type YES to continue: " CONFIRM
        [[ "$CONFIRM" == "YES" ]] && ensure_service_target_context && sync_settings_repo ;;
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
    echo "2 - Crash Share Root: (${CRASH_SHARE_ROOT})"
    echo "3 - Source URLs and Branches"
    if has_cmangos_source_profile; then
      echo "4 - CMaNGOS Build Profile"
      echo "    Profile: $(cmangos_build_profile) ($(cmangos_build_profile_label))"
      echo "    Repo: $(expansion_repo "$EXPANSION")"
      echo "    Branch: $(expansion_branch "$EXPANSION")"
    fi
    if is_vmangos; then
      echo "4 - vMaNGOS Instance Names"
      echo "    $(vmangos_instance_summary)"
      echo "5 - vMaNGOS Source Pin"
      echo "    Repo: $(expansion_repo "$EXPANSION")"
      echo "    Branch: $(expansion_branch "$EXPANSION")"
    fi
    echo "0 - Back"
    echo
    read -p "Selection: " CSEL
    case "$CSEL" in
      1)
        require_existing_game_container || continue
        derive_db_names || return 1
        check_and_update_botconf
        read -p "Press Enter to continue..."
        ;;
      2)
        edit_crash_share_root
        ;;
      3)
        edit_operator_sources
        ;;
      4)
        if is_vmangos; then
          edit_vmangos_instance_names
        elif has_cmangos_source_profile; then
          edit_cmangos_source_profile
        fi
        ;;
      5)
        if is_vmangos; then
          edit_vmangos_source_pin
        fi
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
    if is_vmangos; then
        echo "1 - Release Clean Rebuild"
        echo "2 - Release Update + Rebuild"
        echo "3 - Configure Modules (Unavailable for vMaNGOS)"
        echo "4 - Default Debug Build"
        echo "5 - Custom Branch Build (Debug)"
    else
      echo "1 - Clean Rebuild"
      echo "2 - Incremental Update"
      echo "3 - Configure Modules"
    fi
    echo "0 - Back"
    echo

    read -p "Selection: " CORE

    case "$CORE" in
      1)
        if is_vmangos; then
            read -p "Confirm vMaNGOS release clean rebuild? (YES): " CONFIRM
            if [[ "$CONFIRM" == "YES" ]]; then
              ensure_service_target_context || continue
              vmangos_run_lane_action release-clean
              echo
              read -p "vMaNGOS release clean rebuild finished. Press Enter to continue..." _
            fi
        else
          read -p "Confirm rebuild? (Y/N): " CONFIRM
          if [[ "${CONFIRM^^}" == "Y" ]]; then
            ensure_service_target_context || continue
            pct exec "$GAME_CTID" -- rm -rf /opt/source
            comp_server
            echo
            read -p "Core rebuild finished. Press Enter to continue..." _
          fi
        fi
        ;;
      2)
        if is_vmangos; then
            read -p "Confirm vMaNGOS release update + rebuild? (YES): " CONFIRM
            if [[ "$CONFIRM" == "YES" ]]; then
              ensure_service_target_context || continue
              vmangos_run_lane_action release-update
              echo
              read -p "vMaNGOS release update + rebuild finished. Press Enter to continue..." _
            fi
        else
          read -p "Confirm update? (YES): " CONFIRM
          if [[ "$CONFIRM" == "YES" ]]; then
            ensure_service_target_context || continue
            update_core
            echo
            read -p "Core update finished. Press Enter to continue..." _
          fi
        fi
        ;;
      3)
        if is_vmangos; then
          echo
          echo "Module configuration is unavailable for vMaNGOS lanes."
          read -p "Press Enter to continue..." _
        else
          configure_modules
        fi
        ;;
      4)
        if is_vmangos; then
          read -p "Confirm bridge debug build? (YES): " CONFIRM
          if [[ "$CONFIRM" == "YES" ]]; then
            ensure_service_target_context || continue
              vmangos_run_lane_action debug
              echo
              read -p "Default vMaNGOS debug build finished. Press Enter to continue..." _
            fi
        fi
        ;;
      5)
        if is_vmangos; then
            read -p "Confirm custom vMaNGOS debug build? (YES): " CONFIRM
            if [[ "$CONFIRM" == "YES" ]]; then
              ensure_service_target_context || continue
              vmangos_run_lane_action custom-debug
              echo
              read -p "Custom vMaNGOS debug build finished. Press Enter to continue..." _
            fi
        fi
        ;;
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
      set_or_append_config_line "MODULE_${mod}" "${new}"
      persist_config_storage
      echo "  $mod → $new"
      sleep 0.5
    fi
  done
}

ensure_vmangos_build_deps() {
  is_vmangos || return 0

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    missing=0
    for pkg in git build-essential cmake mariadb-client rsync \
      libssl-dev libbz2-dev libreadline-dev libcurl4-openssl-dev \
      zlib1g-dev libncurses-dev libmariadb-dev libmariadb-dev-compat \
      libboost-all-dev libace-dev libtbb-dev unzip wget p7zip-full gdb; do
      dpkg -s \"\$pkg\" >/dev/null 2>&1 || { missing=1; break; }
    done

    if [[ \"\$missing\" -eq 1 ]]; then
      apt update
      apt install -y \
        git build-essential cmake \
        mariadb-client rsync \
        libssl-dev libbz2-dev libreadline-dev \
        libcurl4-openssl-dev zlib1g-dev \
        libncurses-dev libmariadb-dev libmariadb-dev-compat \
        libboost-all-dev libace-dev libtbb-dev unzip wget p7zip-full \
        gdb
    fi
  "
}

apply_vmangos_build_fix_patch() {
  is_vmangos || return 0

  local HOST_PATCH="${SCRIPT_DIR}/patches/vmangos/0001-vmangos-ike3-playerbots-build-fixes.patch"
  local HOST_PATCH_FALLBACK="${SCRIPT_DIR}/.local/patches/vmangos/0001-vmangos-ike3-playerbots-build-fixes.patch"
  local CT_PATCH="/opt/spp-patches/vmangos/0001-vmangos-ike3-playerbots-build-fixes.patch"
  local BRANCH
  BRANCH=$(expansion_branch "$EXPANSION") || return 1

  if [[ "$BRANCH" == "codex/vmangos-bot-loot-roll-port" ]]; then
    echo "Skipping legacy vMaNGOS build fix patch for $BRANCH."
    return 0
  fi

  if [[ ! -f "$HOST_PATCH" && -f "$HOST_PATCH_FALLBACK" ]]; then
    HOST_PATCH="$HOST_PATCH_FALLBACK"
  fi

  if [[ ! -f "$HOST_PATCH" ]]; then
    pct exec "$GAME_CTID" -- bash -c "
      set -e
      cd /opt/source

      patch_baseline_present() {
        grep -Fq 'add_library(zlib INTERFACE)' CMakeLists.txt \
          && grep -Fq '\${CMAKE_CURRENT_SOURCE_DIR}/PlayerBots' src/game/CMakeLists.txt \
          && grep -Fq 'add_subdirectory(PlayerBots)' src/game/CMakeLists.txt \
          && grep -Fq 'strnicmp(' src/game/PlayerBots/playerbot/PlayerbotAI.cpp \
          && grep -Fq 'strnicmp(' src/game/PlayerBots/playerbot/strategy/actions/SayAction.cpp \
          && grep -Fq '#define SUPPORTED_CLIENT_BUILD 5875' src/shared/Progression.h
      }

      if patch_baseline_present; then
        echo 'Skipping legacy vMaNGOS build fix patch: patch file is absent, but the required compatibility baseline is already present.'
        exit 0
      fi

      echo 'Missing vMaNGOS build-fix patch on launcher host, and the expected compatibility baseline was not detected in source.'
      exit 1
    "
    return $?
  fi

  pct exec "$GAME_CTID" -- mkdir -p /opt/spp-patches/vmangos
  pct push "$GAME_CTID" "$HOST_PATCH" "$CT_PATCH"

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt/source
    patch_file='$CT_PATCH'

    patch_baseline_present() {
      grep -Fq 'add_library(zlib INTERFACE)' CMakeLists.txt \
        && grep -Fq '\${CMAKE_CURRENT_SOURCE_DIR}/PlayerBots' src/game/CMakeLists.txt \
        && grep -Fq 'add_subdirectory(PlayerBots)' src/game/CMakeLists.txt \
        && grep -Fq 'strnicmp(' src/game/PlayerBots/playerbot/PlayerbotAI.cpp \
        && grep -Fq 'strnicmp(' src/game/PlayerBots/playerbot/strategy/actions/SayAction.cpp \
        && grep -Fq '#define SUPPORTED_CLIENT_BUILD 5875' src/shared/Progression.h
    }

    if git apply --reverse --check \"\$patch_file\" >/dev/null 2>&1; then
      echo 'vMaNGOS build fix patch already applied.'
      exit 0
    fi

    if git apply --check \"\$patch_file\" >/dev/null 2>&1; then
      git apply \"\$patch_file\"
      echo 'Applied vMaNGOS build fix patch.'
      exit 0
    fi

    if patch_baseline_present; then
      echo 'Skipping legacy vMaNGOS build fix patch: branch already contains the required compatibility baseline or has diverged beyond this patch.'
      exit 0
    fi

    echo 'Legacy vMaNGOS build fix patch does not apply, and the expected compatibility baseline was not detected in source.'
    exit 1
  "
}

vmangos_persist_source_pin() {
  local target="${1:-$EXPANSION}"
  local repo="$2"
  local branch="$3"
  local repo_var
  local branch_var

  repo_var=$(vmangos_repo_var_name "$target")
  branch_var=$(vmangos_branch_var_name "$target")

  printf -v "$repo_var" '%s' "$repo"
  printf -v "$branch_var" '%s' "$branch"

  set_or_append_config_line "$repo_var" "\"${!repo_var}\""
  set_or_append_config_line "$branch_var" "\"${!branch_var}\""

  if vmangos_is_main_target "$target"; then
    VMANGOS_REPO_URL="$repo"
    VMANGOS_GIT_BRANCH="$branch"
    set_or_append_config_line "VMANGOS_REPO_URL" "\"${VMANGOS_REPO_URL}\""
    set_or_append_config_line "VMANGOS_GIT_BRANCH" "\"${VMANGOS_GIT_BRANCH}\""
  fi

  persist_config_storage
}

vmangos_prompt_source_values() {
  local default_repo="$1"
  local default_branch="$2"
  local prompt_label="$3"
  local entered_repo entered_branch

  echo
  echo "${prompt_label}"
  echo "Leave a field blank to accept the preset."
  echo
  read -p "Repo [${default_repo}]: " entered_repo
  read -p "Branch [${default_branch}]: " entered_branch

  VMANGOS_PROMPTED_REPO="${entered_repo:-$default_repo}"
  VMANGOS_PROMPTED_BRANCH="${entered_branch:-$default_branch}"
}

vmangos_prepare_source_tree() {
  local repo="$1"
  local branch="$2"
  local clean_mode="${3:-0}"

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt

    if [[ '$clean_mode' == '1' ]]; then
      rm -rf source
    fi

    if [[ -d source/.git ]]; then
      echo 'Refreshing existing vMaNGOS source tree...'
      cd source
      git remote set-url origin '$repo'
      git fetch origin
      git checkout '$branch' || git checkout -B '$branch' 'origin/$branch'
      git reset --hard 'origin/$branch'
      git clean -fd
    else
      echo 'Cloning vMaNGOS source tree...'
      git clone '$repo' source
      cd source
      git checkout '$branch' || git checkout -B '$branch' 'origin/$branch'
    fi
  "
}

vmangos_pull_source_tree() {
  local repo="$1"
  local branch="$2"

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt

    if [[ ! -d source/.git ]]; then
      echo 'No existing vMaNGOS source tree found; cloning fresh.'
      git clone '$repo' source
      cd source
      git checkout '$branch' || git checkout -B '$branch' 'origin/$branch'
      exit 0
    fi

    cd source
    git remote set-url origin '$repo'
    git fetch origin
    git checkout '$branch' || git checkout -B '$branch' 'origin/$branch'
    git pull --ff-only origin '$branch'
  "
}

vmangos_build_extractors_flag() {
  if pct exec "$GAME_CTID" -- test -x "$INSTALL_DIR/bin/realmd"; then
    echo "OFF"
  else
    echo "ON"
  fi
}

vmangos_configure_build_dir() {
  local build_type="$1"
  local build_dir_name="$2"
  local reconfigure_mode="${3:-fresh}"
  local extractors_flag="$4"

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    BUILD_DIR='/opt/source/${build_dir_name}'

    configure_lane() {
      cd /opt/source
      cmake -S . -B \"\$BUILD_DIR\" \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DCMAKE_BUILD_TYPE=${build_type} \
        -DBUILD_EXTRACTORS=${extractors_flag} \
        -DBUILD_PLAYERBOTS=ON \
        -DSUPPORTED_CLIENT_BUILD=5875
    }

    if [[ '${reconfigure_mode}' == 'fresh' ]]; then
      rm -rf \"\$BUILD_DIR\"
    fi

    if [[ '${reconfigure_mode}' == 'fallback' ]]; then
      if ! configure_lane; then
        echo 'Existing vMaNGOS build directory is invalid; wiping and reconfiguring.'
        rm -rf \"\$BUILD_DIR\"
        configure_lane
      fi
    else
      configure_lane
    fi
  "
}

vmangos_install_build_dir() {
  local build_dir_name="$1"

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cmake --build '/opt/source/${build_dir_name}' -- -j\$(nproc)
    cd '/opt/source/${build_dir_name}'
    make install
    mkdir -p /var/log/mangos/
    cd '$INSTALL_DIR/etc' || exit 1

    for f in *.conf.dist; do
      base=\${f%.dist}
      [[ -f \$base ]] && continue
      cp \$f \$base
    done
  "
}

vmangos_run_lane_action() {
  is_vmangos || return 1
  derive_db_names || return 1
  ensure_vmangos_build_deps

  local action="$1"
  local repo
  repo=$(vmangos_default_repo "$EXPANSION")
  local branch="$DEFAULT_VMANGOS_GIT_BRANCH"
  local build_type="RelWithDebInfo"
  local build_dir_name="build"
  local reconfigure_mode="fresh"
  local clean_source=0
  local extractors_flag

  case "$action" in
    release-clean|bridge-clean)
      clean_source=1
      ;;
    release-update|bridge-update)
      reconfigure_mode="fallback"
      ;;
    debug|bridge-debug)
      build_type="Debug"
      build_dir_name="build-debug"
      ;;
    custom-debug|ahbot-release|ahbot-debug)
      vmangos_prompt_source_values \
        "$(vmangos_default_repo "$EXPANSION")" \
        "$DEFAULT_VMANGOS_GIT_BRANCH" \
        "Custom vMaNGOS source pin for $(expansion_title "$EXPANSION"):"
      repo="$VMANGOS_PROMPTED_REPO"
      branch="$VMANGOS_PROMPTED_BRANCH"
      build_type="Debug"
      build_dir_name="build-debug"
      ;;
    *)
      echo "Unknown vMaNGOS lane action: $action"
      return 1
      ;;
  esac

  vmangos_persist_source_pin "$EXPANSION" "$repo" "$branch" || {
    echo "Failed to persist the selected vMaNGOS source pin."
    return 1
  }

  if [[ "$action" == "release-update" || "$action" == "bridge-update" ]]; then
    vmangos_pull_source_tree "$repo" "$branch" || return 1
  else
    vmangos_prepare_source_tree "$repo" "$branch" "$clean_source" || return 1
  fi

  apply_vmangos_build_fix_patch || return 1
  extractors_flag=$(vmangos_build_extractors_flag)

  stop_mangosd_managed "vmangos-lane-build"
  vmangos_configure_build_dir "$build_type" "$build_dir_name" "$reconfigure_mode" "$extractors_flag" || return 1
  vmangos_install_build_dir "$build_dir_name" || return 1
  start_mangosd_managed "vmangos-lane-build"

  update_core_metadata
  update_db_conf
  check_and_update_botconf
}

test_build_vmangos() {
  is_vmangos || return 1
  vmangos_run_lane_action debug
}

comp_server() {
  derive_db_names || return 1
  local REPO BRANCH
  REPO=$(expansion_repo "$EXPANSION") || return 1
  BRANCH=$(expansion_branch "$EXPANSION") || return 1

  if is_vmangos; then
    vmangos_run_lane_action release-clean
    return $?
  fi

  if [[ "$EXPANSION" == "classic" ]] && is_tortoise_profile; then
    echo "Tortoise/Turtle WoW source is pinned, but the native LXC build/install lane is not wired yet."
    echo "Use this profile for planning/source pins only until the Turtle CMake, SQL, and data extraction flow is added."
    return 1
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
  local BUILD_MODULES_FLAG="-DBUILD_MODULES=ON"
  if [[ "$EXPANSION" == "classic" && "$(cmangos_build_profile)" == "standard" ]]; then
    MODULE_FLAGS=""
    BUILD_MODULES_FLAG="-DBUILD_MODULES=OFF"
  else
    MODULE_FLAGS=$(build_module_flags)
  fi
  local EXPECTED_MODULES=""
  if [[ "$BUILD_MODULES_FLAG" == "-DBUILD_MODULES=ON" ]]; then
    for mod in "${SPP_MODULES[@]}"; do
      local var="MODULE_${mod}"
      local val="${!var:-ON}"
      if [[ "$val" == "ON" ]]; then
        EXPECTED_MODULES+=" $(echo "$mod" | tr '[:upper:]' '[:lower:]')"
      fi
    done
  fi

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
      $BUILD_MODULES_FLAG \
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
      $BUILD_MODULES_FLAG \
      -DBUILD_GIT_ID=ON \
      $MODULE_FLAGS
    GENERATED_MODULES_FILE='/opt/source/src/modules/modules/src/Modules.cpp'
    if [[ -n \"$EXPECTED_MODULES\" && ! -f \"\$GENERATED_MODULES_FILE\" ]]; then
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
    ensure_vmangos_build_deps

    local OLD_CORE
    OLD_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD 2>/dev/null || echo "")

    pct exec "$GAME_CTID" -- bash -c "
      set -e
      cd /opt/source
      git fetch origin
      git checkout '$(expansion_branch "$EXPANSION")'
      git reset --hard 'origin/$(expansion_branch "$EXPANSION")'
      git clean -fd
    "

    apply_vmangos_build_fix_patch

    local NEW_CORE
    NEW_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)

    if [[ "$OLD_CORE" != "$NEW_CORE" ]] || ! pct exec "$GAME_CTID" -- git -C /opt/source diff --quiet --exit-code; then
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

  if [[ "$EXPANSION" == "classic" ]] && is_tortoise_profile; then
    echo "Tortoise/Turtle WoW source is pinned, but incremental core rebuild is not wired yet."
    return 1
  fi

  local REPO BRANCH
  REPO=$(expansion_repo "$EXPANSION") || return 1
  BRANCH=$(expansion_branch "$EXPANSION") || return 1
  local OLD_CORE OLD_BOT
  OLD_CORE=$(pct exec "$GAME_CTID" -- git -C /opt/source rev-parse HEAD)
  OLD_BOT=$(pct exec "$GAME_CTID" -- git -C /opt/source/src/modules/playerbot rev-parse HEAD)
  local MODULE_FLAGS
  local BUILD_MODULES_FLAG="-DBUILD_MODULES=ON"
  if [[ "$EXPANSION" == "classic" && "$(cmangos_build_profile)" == "standard" ]]; then
    MODULE_FLAGS=""
    BUILD_MODULES_FLAG="-DBUILD_MODULES=OFF"
  else
    MODULE_FLAGS=$(build_module_flags)
  fi
  local EXPECTED_MODULES=""
  if [[ "$BUILD_MODULES_FLAG" == "-DBUILD_MODULES=ON" ]]; then
    for mod in "${SPP_MODULES[@]}"; do
      local var="MODULE_${mod}"
      local val="${!var:-ON}"
      if [[ "$val" == "ON" ]]; then
        EXPECTED_MODULES+=" $(echo "$mod" | tr '[:upper:]' '[:lower:]')"
      fi
    done
  fi

  pct exec "$GAME_CTID" -- bash -c "
    set -e
    cd /opt/source
    git remote set-url origin '$REPO'
    git fetch
    git checkout '$BRANCH'
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
        $BUILD_MODULES_FLAG \
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
    vmangos|vmangos-*)
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
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && install_db
        ;;
      2)
        read -p "Confirm reset? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && reset_characters
        ;;
      3)         
	    read -p "Confirm install? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && install_locales ;;
	  4)         
	    read -p "Confirm update on realmd? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && update_db_type realmd ;;
	  5)         
	    read -p "Confirm update on characters? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && update_db_type characters ;;
	  6)         
	    read -p "Confirm update on PlayerBots? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && update_db_type playerbot ;;
      7)
        read -p "Configure bot rotation logging now? (Y/N): " CONFIRM
        [[ "$CONFIRM" == "Y" ]] && { ! is_vmangos || require_existing_game_container; } && configure_bot_rotation_log
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
  if is_vmangos && ! vmangos_uses_shared_realmd; then
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
    resolve_vmangos_db_endpoint || return 1

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      ASSET_BASE='/opt/spp-assets/vmangos/sql'
      SQL_BASE='/opt/source/sql'
      PLAYERBOT_SQL_BASE='/opt/source/src/game/PlayerBots/sql'
      TMP_DIR='/tmp/vmangos-sql'
      DEFAULT_WORLD_URL='${VMANGOS_WORLD_DB_URL}'
      MYSQL_ARGS=(--skip-ssl --host='${DB_IP}' --port='${DB_PORT}' --user='${DB_LAN_USER}')
      mkdir -p \"\$ASSET_BASE\"
      mkdir -p \"\$TMP_DIR\"
      rm -rf \"\$TMP_DIR/extracted\"
      mkdir -p \"\$TMP_DIR/extracted\"

      WORLD_SQL=''
      if [[ -f \"\$ASSET_BASE/world.sql\" ]]; then
        WORLD_SQL=\"\$ASSET_BASE/world.sql\"
      elif [[ -f \"\$ASSET_BASE/world.7z\" ]]; then
        rm -f \"\$TMP_DIR/world.sql\"
        7z x -y \"\$ASSET_BASE/world.7z\" -o\"\$TMP_DIR/extracted\" >/dev/null
        WORLD_SQL=\$(find \"\$TMP_DIR/extracted\" -maxdepth 2 -type f -name '*.sql' | sort | head -n1)
      else
        mapfile -t WORLD_SQL_CANDIDATES < <(find \"\$ASSET_BASE\" -maxdepth 1 -type f \\( -name 'world*.sql' -o -name '*world*.sql' \\) | sort)
        mapfile -t WORLD_ARCHIVE_CANDIDATES < <(find \"\$ASSET_BASE\" -maxdepth 1 -type f \\( -name 'world*.7z' -o -name '*world*.7z' \\) | sort)

        if (( \${#WORLD_SQL_CANDIDATES[@]} > 0 )); then
          WORLD_SQL=\"\${WORLD_SQL_CANDIDATES[-1]}\"
        elif (( \${#WORLD_ARCHIVE_CANDIDATES[@]} > 0 )); then
          WORLD_ARCHIVE=\"\${WORLD_ARCHIVE_CANDIDATES[-1]}\"
          7z x -y \"\$WORLD_ARCHIVE\" -o\"\$TMP_DIR/extracted\" >/dev/null
          WORLD_SQL=\$(find \"\$TMP_DIR/extracted\" -maxdepth 2 -type f -name '*.sql' | sort | head -n1)
        elif [[ -n \"\$DEFAULT_WORLD_URL\" ]]; then
          WORLD_ARCHIVE=\"\$ASSET_BASE/\$(basename \"\$DEFAULT_WORLD_URL\")\"
          if [[ ! -f \"\$WORLD_ARCHIVE\" ]]; then
            if command -v curl >/dev/null 2>&1; then
              curl -L --fail --output \"\$WORLD_ARCHIVE\" \"\$DEFAULT_WORLD_URL\"
            elif command -v wget >/dev/null 2>&1; then
              wget -O \"\$WORLD_ARCHIVE\" \"\$DEFAULT_WORLD_URL\"
            else
              echo 'Missing curl/wget to download default vMaNGOS world DB asset.'
              exit 1
            fi
          fi
          7z x -y \"\$WORLD_ARCHIVE\" -o\"\$TMP_DIR/extracted\" >/dev/null
          WORLD_SQL=\$(find \"\$TMP_DIR/extracted\" -maxdepth 2 -type f -name '*.sql' | sort | head -n1)
        fi
      fi

      if [[ -z \"\$WORLD_SQL\" || ! -f \"\$WORLD_SQL\" ]]; then
        echo 'Missing vMaNGOS world DB asset. Stage world.sql, world.7z, or a world_full*.7z release in /opt/spp-assets/vmangos/sql, or set VMANGOS_WORLD_DB_URL to a downloadable archive.'
        exit 1
      fi

      echo \"[\$(date '+%F %T')] Importing world base: \$(basename \"\$WORLD_SQL\")\"
      mariadb \"\${MYSQL_ARGS[@]}\" -e \"
        DROP DATABASE IF EXISTS ${WORLD_DB};
        CREATE DATABASE ${WORLD_DB} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"
      mariadb \"\${MYSQL_ARGS[@]}\" '${WORLD_DB}' < \"\$WORLD_SQL\"

      mapfile -t WORLD_MIGRATIONS < <(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_world.sql' | sort)
      WORLD_TOTAL=\${#WORLD_MIGRATIONS[@]}
      WORLD_INDEX=0
      for f in \"\${WORLD_MIGRATIONS[@]}\"; do
        WORLD_INDEX=\$((WORLD_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying world migration \$WORLD_INDEX/\$WORLD_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${WORLD_DB}' < \"\$f\"
      done

      mapfile -t WORLD_OVERRIDES < <(find \"\$ASSET_BASE/world\" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
      WORLD_OVERRIDE_TOTAL=\${#WORLD_OVERRIDES[@]}
      WORLD_OVERRIDE_INDEX=0
      for f in \"\${WORLD_OVERRIDES[@]}\"; do
        WORLD_OVERRIDE_INDEX=\$((WORLD_OVERRIDE_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying world override \$WORLD_OVERRIDE_INDEX/\$WORLD_OVERRIDE_TOTAL: \$(basename \"\$f\")\"
        [[ -f \"\$f\" ]] && mariadb \"\${MYSQL_ARGS[@]}\" '${WORLD_DB}' < \"\$f\"
      done

      mapfile -t PLAYERBOT_WORLD_SQL < <(
        {
          find \"\$PLAYERBOT_SQL_BASE/world\" -maxdepth 1 -type f -name '*.sql' 2>/dev/null
          find \"\$PLAYERBOT_SQL_BASE/world/classic\" -maxdepth 1 -type f -name '*.sql' 2>/dev/null
        } | sort
      )
      PLAYERBOT_WORLD_TOTAL=\${#PLAYERBOT_WORLD_SQL[@]}
      PLAYERBOT_WORLD_INDEX=0
      for f in \"\${PLAYERBOT_WORLD_SQL[@]}\"; do
        PLAYERBOT_WORLD_INDEX=\$((PLAYERBOT_WORLD_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying playerbot world SQL \$PLAYERBOT_WORLD_INDEX/\$PLAYERBOT_WORLD_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${WORLD_DB}' < \"\$f\"
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
  resolve_vmangos_db_endpoint || return 1

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      SQL_BASE='/opt/source/sql'
      PLAYERBOT_SQL_BASE='/opt/source/src/game/PlayerBots/sql/characters'
      MYSQL_ARGS=(--skip-ssl --host='${DB_IP}' --port='${DB_PORT}' --user='${DB_LAN_USER}')

      echo \"[\$(date '+%F %T')] Importing characters base: characters.sql\"
      mariadb \"\${MYSQL_ARGS[@]}\" -e \"
        DROP DATABASE IF EXISTS ${CHAR_DB_NAME};
        CREATE DATABASE ${CHAR_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"

      mariadb \"\${MYSQL_ARGS[@]}\" '${CHAR_DB_NAME}' < \"\$SQL_BASE/characters.sql\"

      mapfile -t CHARACTER_MIGRATIONS < <(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_characters.sql' | sort)
      CHARACTER_TOTAL=\${#CHARACTER_MIGRATIONS[@]}
      CHARACTER_INDEX=0
      for f in \"\${CHARACTER_MIGRATIONS[@]}\"; do
        CHARACTER_INDEX=\$((CHARACTER_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying characters migration \$CHARACTER_INDEX/\$CHARACTER_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${CHAR_DB_NAME}' < \"\$f\"
      done

      mapfile -t CHARACTER_OVERRIDES < <(find /opt/spp-assets/vmangos/sql/characters -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
      CHARACTER_OVERRIDE_TOTAL=\${#CHARACTER_OVERRIDES[@]}
      CHARACTER_OVERRIDE_INDEX=0
      for f in \"\${CHARACTER_OVERRIDES[@]}\"; do
        CHARACTER_OVERRIDE_INDEX=\$((CHARACTER_OVERRIDE_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying characters override \$CHARACTER_OVERRIDE_INDEX/\$CHARACTER_OVERRIDE_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${CHAR_DB_NAME}' < \"\$f\"
      done

      mapfile -t PLAYERBOT_CHARACTER_SQL < <(find \"\$PLAYERBOT_SQL_BASE\" -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
      PLAYERBOT_CHARACTER_TOTAL=\${#PLAYERBOT_CHARACTER_SQL[@]}
      PLAYERBOT_CHARACTER_INDEX=0
      for f in \"\${PLAYERBOT_CHARACTER_SQL[@]}\"; do
        PLAYERBOT_CHARACTER_INDEX=\$((PLAYERBOT_CHARACTER_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying playerbot characters SQL \$PLAYERBOT_CHARACTER_INDEX/\$PLAYERBOT_CHARACTER_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${CHAR_DB_NAME}' < \"\$f\"
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
    resolve_vmangos_db_endpoint || return 1

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      SQL_BASE='/opt/source/sql'
      MYSQL_ARGS=(--skip-ssl --host='${DB_IP}' --port='${DB_PORT}' --user='${DB_LAN_USER}')

      echo \"[\$(date '+%F %T')] Importing logs base: logs.sql\"
      mariadb \"\${MYSQL_ARGS[@]}\" -e \"
        DROP DATABASE IF EXISTS ${LOG_DB_NAME};
        CREATE DATABASE ${LOG_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"

      mariadb \"\${MYSQL_ARGS[@]}\" '${LOG_DB_NAME}' < \"\$SQL_BASE/logs.sql\"

      mapfile -t LOG_MIGRATIONS < <(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_logs.sql' | sort)
      LOG_TOTAL=\${#LOG_MIGRATIONS[@]}
      LOG_INDEX=0
      for f in \"\${LOG_MIGRATIONS[@]}\"; do
        LOG_INDEX=\$((LOG_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying logs migration \$LOG_INDEX/\$LOG_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${LOG_DB_NAME}' < \"\$f\"
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
    resolve_vmangos_db_endpoint || return 1

    if pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      export MYSQL_PWD='${DB_LAN_PASS}'
      SQL_BASE='/opt/source/sql'
      MYSQL_ARGS=(--skip-ssl --host='${DB_IP}' --port='${DB_PORT}' --user='${DB_LAN_USER}')

      echo \"[\$(date '+%F %T')] Importing logon base: logon.sql\"
      mariadb \"\${MYSQL_ARGS[@]}\" -e \"
        DROP DATABASE IF EXISTS ${REALM_DB_NAME};
        CREATE DATABASE ${REALM_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
      \"

      mariadb \"\${MYSQL_ARGS[@]}\" '${REALM_DB_NAME}' < \"\$SQL_BASE/logon.sql\"

      mapfile -t LOGON_MIGRATIONS < <(find \"\$SQL_BASE/migrations\" -maxdepth 1 -type f -name '*_logon.sql' | sort)
      LOGON_TOTAL=\${#LOGON_MIGRATIONS[@]}
      LOGON_INDEX=0
      for f in \"\${LOGON_MIGRATIONS[@]}\"; do
        LOGON_INDEX=\$((LOGON_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying logon migration \$LOGON_INDEX/\$LOGON_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${REALM_DB_NAME}' < \"\$f\"
      done

      mapfile -t LOGON_OVERRIDES < <(find /opt/spp-assets/vmangos/sql/logon -maxdepth 1 -type f -name '*.sql' 2>/dev/null | sort)
      LOGON_OVERRIDE_TOTAL=\${#LOGON_OVERRIDES[@]}
      LOGON_OVERRIDE_INDEX=0
      for f in \"\${LOGON_OVERRIDES[@]}\"; do
        LOGON_OVERRIDE_INDEX=\$((LOGON_OVERRIDE_INDEX + 1))
        echo \"[\$(date '+%F %T')] Applying logon override \$LOGON_OVERRIDE_INDEX/\$LOGON_OVERRIDE_TOTAL: \$(basename \"\$f\")\"
        mariadb \"\${MYSQL_ARGS[@]}\" '${REALM_DB_NAME}' < \"\$f\"
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
    local DEFAULT_ASSET_URL="${VMANGOS_DATA_PACK_URL}"

    pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      mkdir -p '$ASSET_DIR'
      TMP_DIR='/tmp/vmangos-data-pack'
      rm -rf \"\$TMP_DIR\"
      mkdir -p \"\$TMP_DIR\"

      mapfile -t DATA_ARCHIVE_CANDIDATES < <(find /opt/spp-assets/vmangos -maxdepth 1 -type f \\( -name '*data*.zip' -o -name '*data*.7z' -o -name 'vmangos-bropack-*.zip' -o -name 'vmangos-bropack-*.7z' \\) | sort)
      if [[ \${#DATA_ARCHIVE_CANDIDATES[@]} -gt 0 ]]; then
        DATA_ARCHIVE=\"\${DATA_ARCHIVE_CANDIDATES[0]}\"
        echo \"Reinstalling vMaNGOS data pack from staged archive: \$DATA_ARCHIVE\"
      else
        DATA_ARCHIVE=\"/tmp/\$(basename '$DEFAULT_ASSET_URL')\"
        echo 'No staged vMaNGOS data pack found; downloading configured vMaNGOS asset pack...'
        if command -v curl >/dev/null 2>&1; then
          curl -L --fail --output \"\$DATA_ARCHIVE\" '$DEFAULT_ASSET_URL'
        elif command -v wget >/dev/null 2>&1; then
          wget -O \"\$DATA_ARCHIVE\" '$DEFAULT_ASSET_URL'
        else
          echo 'Missing curl/wget to download configured vMaNGOS data pack.'
          exit 1
        fi
      fi

      rm -rf '$ASSET_DIR'/*
      case \"\$DATA_ARCHIVE\" in
        *.zip)
          if command -v 7z >/dev/null 2>&1; then
            7z x -y \"\$DATA_ARCHIVE\" -o\"\$TMP_DIR\" >/dev/null
          elif command -v bsdtar >/dev/null 2>&1; then
            bsdtar -xf \"\$DATA_ARCHIVE\" -C \"\$TMP_DIR\"
          elif command -v unzip >/dev/null 2>&1; then
            unzip -oq \"\$DATA_ARCHIVE\" -d \"\$TMP_DIR\"
          else
            echo 'Missing 7z/bsdtar/unzip to extract configured vMaNGOS zip data pack.'
            exit 1
          fi
          ;;
        *.7z)
          7z x -y \"\$DATA_ARCHIVE\" -o\"\$TMP_DIR\" >/dev/null
          ;;
        *)
          echo \"Unsupported vMaNGOS data pack archive: \$DATA_ARCHIVE\"
          exit 1
          ;;
      esac

      if [[ -d \"\$TMP_DIR/data\" ]]; then
        rsync -a --delete \"\$TMP_DIR/data/\" '$ASSET_DIR/'
      else
        rsync -a --delete \"\$TMP_DIR/\" '$ASSET_DIR/'
      fi
      for required_dir in maps vmaps mmaps; do
        if [[ ! -d '$ASSET_DIR/'\"\$required_dir\" ]]; then
          echo \"Missing required vMaNGOS data directory: $ASSET_DIR/\$required_dir\"
          exit 1
        fi
      done
      if [[ ! -d '$ASSET_DIR/dbc' && ! -d '$ASSET_DIR/5875/dbc' ]]; then
        echo 'Missing required vMaNGOS DBC data directory: expected dbc or 5875/dbc.'
        exit 1
      fi
      mkdir -p '$INSTALL_DIR/data'
      rsync -a --delete '$ASSET_DIR/' '$INSTALL_DIR/data/'
      if [[ ! -d '$INSTALL_DIR/data/5875/dbc' ]]; then
        if [[ -d '$INSTALL_DIR/data/dbc' ]]; then
          mkdir -p '$INSTALL_DIR/data/5875'
          ln -sfn ../dbc '$INSTALL_DIR/data/5875/dbc'
        else
          echo 'Missing installed vMaNGOS DBC data directory after sync.'
          exit 1
        fi
      fi
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

  if [[ "$EXPANSION" == "classic" ]] && is_tortoise_profile; then
    echo "Tortoise/Turtle WoW is configured as the CMaNGOS source profile, but its DB/data installer is not wired yet."
    echo "Required next steps: add Turtle 1.18.1 SQL import, data extraction/import, config deployment, and service mapping."
    echo "Full install is blocked to avoid dropping the existing Classic-family databases into an incompatible layout."
    read -p "Press Enter to continue..." _
    return 1
  fi

  echo "Stopping services..."
  stop_mangosd_managed "full-install"

  if is_vmangos; then
    pct exec "$GAME_CTID" -- systemctl stop realmd 2>/dev/null || true
  elif is_master; then
    pct exec "$LOGIN_CTID" -- systemctl stop realmd 2>/dev/null || true
    pct exec "$WEB_CTID" -- systemctl stop apache2 2>/dev/null || true
  fi

  echo "Removing old install directory..."
  pct exec "$GAME_CTID" -- rm -rf "$INSTALL_DIR"

  if ! is_vmangos && is_master; then
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
  local DROP_ARMORY_SQL=""
  if ! is_vmangos; then
    local ARMORY_DB
    ARMORY_DB=$(expansion_armory_db_name "$EXPANSION") || return 1
    DROP_ARMORY_SQL="mariadb -u root -e \"DROP DATABASE IF EXISTS ${ARMORY_DB};\""
  fi

  pct exec "$DB_CTID" -- bash -c "
    export MYSQL_PWD='${DB_ROOT_PASS}'
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${WORLD_DB};\"
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${CHAR_DB_NAME};\"
    mariadb -u root -e \"DROP DATABASE IF EXISTS ${LOG_DB_NAME};\"
    ${DROP_ARMORY_SQL}
  "

  # Shared-auth lanes drop the shared realm DB from the owning install lane; dedicated vMaNGOS keeps its own realm DB.
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

  local STATUS_CTIDS=("$GAME_CTID" "$WEB_CTID" "$DB_CTID")
  if ! is_vmangos; then
    STATUS_CTIDS+=("$LOGIN_CTID")
  fi

  for CT in "${STATUS_CTIDS[@]}"; do

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

  local START_CTIDS=("$DB_CTID" "$WEB_CTID" "$GAME_CTID")
  if ! is_vmangos; then
    START_CTIDS+=("$LOGIN_CTID")
  fi
  local REALMD_CTID
  REALMD_CTID=$(realmd_ctid)

  for CT in "${START_CTIDS[@]}"; do
    STATE=$(pct status "$CT" | awk '{print $2}')
    if [[ "$STATE" != "running" ]]; then
      pct start "$CT"
      pct exec "$CT" -- bash -c "while ! systemctl is-system-running --quiet 2>/dev/null; do sleep 1; done"
    fi
  done

  pct exec "$DB_CTID" -- systemctl start mariadb
  pct exec "$REALMD_CTID" -- systemctl start realmd
  pct exec "$WEB_CTID" -- systemctl start apache2
  start_mangosd_managed "stack-start"
  sync_bot_rotation_config || true

}

server_info_menu() {
  ensure_expansion_context || return 1
  auto_detect_stack
  LOGIN_IP=$(pct exec "$(realmd_ctid)" -- hostname -I | awk '{print $1}')

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
    echo "9 - Package Crash Bundle"
    echo "10 - Clean Cores + Verified Bundles"
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
      9) package_crash_bundle ;;
      10) cleanup_local_crash_artifacts ;;
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
  pct exec "$(realmd_ctid)" -- nano "$INSTALL_DIR/etc/realmd.conf"
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

  if ! is_vmangos; then
    while IFS= read -r conf; do
      [[ -z "$conf" ]] && continue
      case "$(basename "$conf")" in
        realmd.conf) continue ;;
      esac
      LABELS+=("Login: $(basename "$conf")")
      TARGETS+=("$LOGIN_CTID")
      PATHS+=("$conf")
    done < <(pct exec "$LOGIN_CTID" -- bash -lc "find '$LOGIN_ETC' -maxdepth 1 -type f -name '*.conf' | sort" 2>/dev/null)
  fi

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

package_crash_bundle() {
  derive_db_names || return 1
  local BIN_DIR="$INSTALL_DIR/bin"
  local BINARY="$BIN_DIR/mangosd"
  local HOST_CRASH_SHARE_DEFAULT="${CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"
  local WINDOWS_CRASH_SHARE_DEFAULT='\\ser5\fast\crashlogs'
  local WSL_CRASH_SHARE_DEFAULT="/mnt/z/crashlogs"
  local LOCAL_TAR_SIZE HOST_TAR_SIZE

  local CORES
  CORES=$(pct exec "$GAME_CTID" -- bash -c "
    ls -t '$BIN_DIR'/core* 2>/dev/null || true
  ")

  if [[ -z "$CORES" ]]; then
    echo "No file-based core dumps found in $BIN_DIR."
    echo "This bundle helper currently expects core.<pid> files written into the server bin directory."
    echo "Use 'Analyze Crash (GDB)' for interactive coredumpctl fallback if needed."
    read -p "Press Enter..." _
    return
  fi

  echo "Available core dumps:"
  pct exec "$GAME_CTID" -- bash -c "ls -lht '$BIN_DIR'/core* 2>/dev/null"
  echo

  local LATEST CORE_FILE CORE_BASENAME DEFAULT_BUNDLE_NAME BUNDLE_NAME BUNDLE_DIR TAR_PATH TEXT_HISTORY_DIR
  local HOST_SHARE_ROOT HOST_SHARE_DIR HOST_SHARE_PATH WINDOWS_SHARE_PATH WSL_SHARE_PATH
  LATEST=$(echo "$CORES" | head -1)
  read -p "Core file to package [$LATEST]: " CORE_FILE
  CORE_FILE="${CORE_FILE:-$LATEST}"
  CORE_BASENAME=$(basename "$CORE_FILE")
  DEFAULT_BUNDLE_NAME="crash_bundle_${EXPANSION}_$(date +%Y%m%d_%H%M%S)"

  read -p "Bundle name [$DEFAULT_BUNDLE_NAME]: " BUNDLE_NAME
  BUNDLE_NAME="${BUNDLE_NAME:-$DEFAULT_BUNDLE_NAME}"
  BUNDLE_DIR="$BIN_DIR/$BUNDLE_NAME"
  TAR_PATH="$BIN_DIR/${BUNDLE_NAME}.tar.gz"
  TEXT_HISTORY_DIR="$BIN_DIR/crash_text_history"
  HOST_SHARE_ROOT="$HOST_CRASH_SHARE_DEFAULT"
  HOST_SHARE_DIR="${HOST_SHARE_ROOT}/${EXPANSION}"
  HOST_SHARE_PATH="${HOST_SHARE_DIR}/${BUNDLE_NAME}.tar.gz"
  WINDOWS_SHARE_PATH="${WINDOWS_CRASH_SHARE_DEFAULT}\\${EXPANSION}\\${BUNDLE_NAME}.tar.gz"
  WSL_SHARE_PATH="${WSL_CRASH_SHARE_DEFAULT}/${EXPANSION}/${BUNDLE_NAME}.tar.gz"

  echo "Host crash share target: $HOST_SHARE_PATH"
  read -p "Share root on Proxmox host [$HOST_CRASH_SHARE_DEFAULT]: " HOST_SHARE_ROOT
  HOST_SHARE_ROOT="${HOST_SHARE_ROOT:-$HOST_CRASH_SHARE_DEFAULT}"
  HOST_SHARE_DIR="${HOST_SHARE_ROOT}/${EXPANSION}"
  HOST_SHARE_PATH="${HOST_SHARE_DIR}/${BUNDLE_NAME}.tar.gz"
  if [[ "$HOST_SHARE_ROOT" == "$HOST_CRASH_SHARE_DEFAULT" ]]; then
    WINDOWS_SHARE_PATH="${WINDOWS_CRASH_SHARE_DEFAULT}\\${EXPANSION}\\${BUNDLE_NAME}.tar.gz"
    WSL_SHARE_PATH="${WSL_CRASH_SHARE_DEFAULT}/${EXPANSION}/${BUNDLE_NAME}.tar.gz"
  else
    WINDOWS_SHARE_PATH="(custom host path; map manually if needed)"
    WSL_SHARE_PATH="(custom host path; mount manually if needed)"
  fi

  echo
  echo "Packaging crash bundle in container..."
  pct exec "$GAME_CTID" -- bash -s -- "$BIN_DIR" "$BINARY" "$CORE_FILE" "$BUNDLE_DIR" "$TAR_PATH" <<'__SPP_CRASH_BUNDLE__'
set -euo pipefail

bin_dir="$1"
binary="$2"
core_file="$3"
bundle_dir="$4"
tar_path="$5"

if [[ ! -f "$binary" ]]; then
  echo "mangosd binary not found at $binary" >&2
  exit 1
fi

if [[ ! -f "$core_file" ]]; then
  echo "Core file not found at $core_file" >&2
  exit 1
fi

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"

bundle_binary="${bundle_dir}/mangosd"
cp -a "$binary" "$bundle_binary"

if [[ -f "${binary}.debug" ]]; then
  cp -a "${binary}.debug" "${bundle_dir}/mangosd.debug"
fi

gdb -q "$bundle_binary" "$core_file" \
  -ex "set pagination off" \
  -ex "set logging file ${bundle_dir}/backtrace.txt" \
  -ex "set logging overwrite on" \
  -ex "set logging enabled on" \
  -ex "bt full" \
  -ex "info threads" \
  -ex "thread apply all bt full" \
  -ex "set logging enabled off" \
  -ex "quit"

{
  echo "=== date ==="
  date
  echo
  echo "=== uname ==="
  uname -a
  echo
  echo "=== binary file ==="
  file "$bundle_binary"
  echo
  echo "=== build id ==="
  readelf -n "$bundle_binary" 2>/dev/null | sed -n '/Build ID/ p'
  echo
  echo "=== ldd ==="
  ldd "$bundle_binary"
  echo
  echo "=== sha256 ==="
  sha256sum "$bundle_binary"
  echo
  echo "=== core file ==="
  ls -lh "$core_file"
} > "${bundle_dir}/binary_info.txt"

{
  echo "=== Server.log (last 200) ==="
  tail -n 200 "${bin_dir}/Server.log" 2>/dev/null || true
  echo
  echo "=== Perf.log (last 200) ==="
  tail -n 200 "${bin_dir}/Perf.log" 2>/dev/null || true
  echo
  echo "=== Char.log (last 200) ==="
  tail -n 200 "${bin_dir}/Char.log" 2>/dev/null || true
  echo
  echo "=== Chat.log (last 200) ==="
  tail -n 200 "${bin_dir}/Chat.log" 2>/dev/null || true
  echo
  echo "=== Realmd.log (last 200) ==="
  tail -n 200 "${bin_dir}/Realmd.log" 2>/dev/null || true
} > "${bundle_dir}/log_tail.txt"

{
  echo "=== crash identity ==="
  sed -n '/^Core was generated by /p;/^Program terminated with signal /p;/^\[Current thread is /p' "${bundle_dir}/backtrace.txt"
  echo
  echo "=== current thread backtrace ==="
  awk '
    /^Thread 1 / { in_thread=1 }
    in_thread { print }
    in_thread && /^$/ { exit }
  ' "${bundle_dir}/backtrace.txt"
  echo
  echo "=== top crash-related log lines ==="
  grep -E 'Received SIG|SIGSEGV|SIGABRT|ASSERT|ERROR:' "${bundle_dir}/log_tail.txt" | tail -n 60 || true
} > "${bundle_dir}/crash_summary.txt"

cp -f "$core_file" "${bundle_dir}/$(basename "$core_file")"
tar -C "$bin_dir" -czf "$tar_path" "$(basename "$bundle_dir")"

echo "Bundle directory: $bundle_dir"
echo "Bundle archive: $tar_path"
__SPP_CRASH_BUNDLE__

  echo
  echo "Copying bundle to Proxmox host share..."
  mkdir -p "$HOST_SHARE_DIR"
  pct pull "$GAME_CTID" "$TAR_PATH" "$HOST_SHARE_PATH"

  pct exec "$GAME_CTID" -- bash -c "
    set -euo pipefail
    mkdir -p '$TEXT_HISTORY_DIR'
    for txt in '$BUNDLE_DIR'/*.txt; do
      [[ -e \"\$txt\" ]] || continue
      cp -f \"\$txt\" '$TEXT_HISTORY_DIR/${BUNDLE_NAME}_'\"\$(basename \"\$txt\")\"
    done
  "

  LOCAL_TAR_SIZE=$(pct exec "$GAME_CTID" -- stat -c %s "$TAR_PATH")
  HOST_TAR_SIZE=$(stat -c %s "$HOST_SHARE_PATH")
  if [[ "$LOCAL_TAR_SIZE" != "$HOST_TAR_SIZE" ]]; then
    echo
    echo "Host copy verification failed for $HOST_SHARE_PATH."
    echo "Local tarball size: $LOCAL_TAR_SIZE"
    echo "Host tarball size:  $HOST_TAR_SIZE"
    read -p "Press Enter..." _
    return 1
  fi

  echo
  echo "Crash bundle created:"
  echo "  Directory: $BUNDLE_DIR"
  echo "  Archive:   $TAR_PATH"
  echo "  Share:     $HOST_SHARE_PATH"
  echo "  Verified:  host copy matches local tarball size"
  echo "  Windows:   $WINDOWS_SHARE_PATH"
  echo "  WSL:       $WSL_SHARE_PATH"
  echo "  Texts:     $TEXT_HISTORY_DIR"
  echo
  echo "Bundle contents:"
  echo "  crash_summary.txt"
  echo "  backtrace.txt"
  echo "  binary_info.txt"
  echo "  mangosd"
  echo "  log_tail.txt"
  echo "  $(basename "$CORE_FILE")"
  echo
  read -p "Remove local bundle directory and tarball after verified host copy? [Y/n]: " REMOVE_LOCAL_BUNDLE
  REMOVE_LOCAL_BUNDLE="${REMOVE_LOCAL_BUNDLE:-Y}"
  if [[ "$REMOVE_LOCAL_BUNDLE" =~ ^[Yy]$ ]]; then
    pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      rm -f '$TAR_PATH'
      rm -rf '$BUNDLE_DIR'
    "
    echo "Copied bundle text artifacts to $TEXT_HISTORY_DIR and removed the local bundle directory and tarball."
  fi
  read -p "Press Enter..." _
}

cleanup_local_crash_artifacts() {
  derive_db_names || return 1
  local BIN_DIR="$INSTALL_DIR/bin"
  local HOST_CRASH_SHARE_DEFAULT="${CRASH_SHARE_ROOT:-$DEFAULT_CRASH_SHARE_ROOT}"
  local SHARE_DIR="${HOST_CRASH_SHARE_DEFAULT}/${EXPANSION}"
  local TEXT_HISTORY_DIR="$BIN_DIR/crash_text_history"
  local UNVERIFIED_KEEP_COUNT=4
  local -a VERIFIED_BUNDLES=()
  local -a MISSING_BUNDLES=()
  local -a RETAINED_UNVERIFIED_BUNDLES=()
  local -a PRUNED_UNVERIFIED_BUNDLES=()
  local LOCAL_TAR LOCAL_NAME LOCAL_SIZE HOST_SIZE BUNDLE_DIR

  echo "=== Local crash artifacts in $BIN_DIR ==="
  pct exec "$GAME_CTID" -- bash -c "
    shopt -s nullglob
    files=( '$BIN_DIR'/core* '$BIN_DIR'/crash_bundle* )
    if [[ \${#files[@]} -eq 0 ]]; then
      echo 'None found.'
    else
      ls -lht \"\${files[@]}\"
    fi
  "
  echo
  echo "=== Archived bundles on host share ==="
  if [[ -d "$SHARE_DIR" ]]; then
    ls -lht "$SHARE_DIR"/*.tar.gz 2>/dev/null || echo "No archived tarballs found in $SHARE_DIR."
  else
    echo "Host share directory does not exist yet: $SHARE_DIR"
  fi
  echo
  echo "Text history folder: $TEXT_HISTORY_DIR"
  echo

  while IFS= read -r LOCAL_TAR; do
    [[ -n "$LOCAL_TAR" ]] || continue
    LOCAL_NAME=$(basename "$LOCAL_TAR")
    LOCAL_SIZE=$(pct exec "$GAME_CTID" -- stat -c %s "$LOCAL_TAR" 2>/dev/null || true)
    if [[ -n "$LOCAL_SIZE" && -f "$SHARE_DIR/$LOCAL_NAME" ]]; then
      HOST_SIZE=$(stat -c %s "$SHARE_DIR/$LOCAL_NAME" 2>/dev/null || true)
      if [[ -n "$HOST_SIZE" && "$LOCAL_SIZE" == "$HOST_SIZE" ]]; then
        VERIFIED_BUNDLES+=("$LOCAL_NAME")
      else
        MISSING_BUNDLES+=("$LOCAL_NAME")
      fi
    else
      MISSING_BUNDLES+=("$LOCAL_NAME")
    fi
  done < <(pct exec "$GAME_CTID" -- bash -c "ls -1 '$BIN_DIR'/crash_bundle*.tar.gz 2>/dev/null || true")

  echo "=== Share Verification Summary ==="
  if [[ ${#VERIFIED_BUNDLES[@]} -gt 0 ]]; then
    printf 'Verified on host share (same filename and size):\n'
    printf '  %s\n' "${VERIFIED_BUNDLES[@]}"
  else
    echo "No local crash bundle tarballs were verified on the host share."
  fi

  if [[ ${#MISSING_BUNDLES[@]} -gt 0 ]]; then
    printf 'Missing on host share or size mismatch:\n'
    printf '  %s\n' "${MISSING_BUNDLES[@]}"
  fi
  echo
  echo "This moves local bundle text artifacts into $TEXT_HISTORY_DIR,"
  echo "deletes local core files, removes any local crash bundles verified on the host share,"
  echo "and keeps only the newest ${UNVERIFIED_KEEP_COUNT} unverified local tarballs."
  read -p "Type YES to clean local crash files in $BIN_DIR: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || return

  pct exec "$GAME_CTID" -- bash -c "
    set -euo pipefail
    shopt -s nullglob
    cd '$BIN_DIR'
    rm -f core.*
    mkdir -p '$TEXT_HISTORY_DIR'
    for bundle_dir in crash_bundle*; do
      [[ -d \"\$bundle_dir\" ]] || continue
      for txt in \"\$bundle_dir\"/*.txt; do
        [[ -e \"\$txt\" ]] || continue
        cp -f \"\$txt\" '$TEXT_HISTORY_DIR/'\"\${bundle_dir}_\$(basename \"\$txt\")\"
      done
    done
  "

  for LOCAL_NAME in "${VERIFIED_BUNDLES[@]}"; do
    BUNDLE_DIR="${LOCAL_NAME%.tar.gz}"
    pct exec "$GAME_CTID" -- bash -c "
      set -euo pipefail
      rm -f '$BIN_DIR/$LOCAL_NAME'
      rm -rf '$BIN_DIR/$BUNDLE_DIR'
    "
  done

  if [[ ${#MISSING_BUNDLES[@]} -gt 0 ]]; then
    local idx=0
    for LOCAL_NAME in "${MISSING_BUNDLES[@]}"; do
      BUNDLE_DIR="${LOCAL_NAME%.tar.gz}"
      if (( idx < UNVERIFIED_KEEP_COUNT )); then
        RETAINED_UNVERIFIED_BUNDLES+=("$LOCAL_NAME")
      else
        PRUNED_UNVERIFIED_BUNDLES+=("$LOCAL_NAME")
        pct exec "$GAME_CTID" -- bash -c "
          set -euo pipefail
          rm -f '$BIN_DIR/$LOCAL_NAME'
          rm -rf '$BIN_DIR/$BUNDLE_DIR'
        "
      fi
      idx=$((idx + 1))
    done
  fi

  pct exec "$GAME_CTID" -- df -h "$BIN_DIR"
  echo
  echo "Local core files removed from $BIN_DIR."
  if [[ ${#VERIFIED_BUNDLES[@]} -gt 0 ]]; then
    echo "Verified local crash bundle tarballs/directories were removed after host-share comparison."
    echo "Their text artifacts were copied into $TEXT_HISTORY_DIR."
  else
    echo "No verified local crash bundle tarballs were removed."
  fi
  if [[ ${#PRUNED_UNVERIFIED_BUNDLES[@]} -gt 0 ]]; then
    echo "Older unverified local crash bundles beyond the newest ${UNVERIFIED_KEEP_COUNT} were pruned."
  fi
  if [[ ${#RETAINED_UNVERIFIED_BUNDLES[@]} -gt 0 ]]; then
    echo "Newest unverified local crash bundles were kept in place:"
    printf '  %s\n' "${RETAINED_UNVERIFIED_BUNDLES[@]}"
  elif [[ ${#MISSING_BUNDLES[@]} -gt 0 ]]; then
    echo "No unverified local crash bundles were retained."
  fi
  read -p "Press Enter..." _
}
#program starts here
run_startup_auto_update_if_needed
run_startup_scan
main
