#!/usr/bin/env bash
# sync_guild_strategies.sh — Syncs guild flavor strategies into ai_playerbot_db_store.
#
# For each guild in the JSON:
#   - flavor != "default": writes co/nc/react strategy rows per member
#   - flavor == "default": removes any override rows (bots fall back to global conf)
#
# Idempotent — safe to run repeatedly (deletes before re-inserting).
# Run after scan_guilds.sh, or on a cron schedule.
#
# Usage:
#   REALM=1 DB_PASS=secret bash sync_guild_strategies.sh
#   REALM=2 DB_PASS=secret DB_HOST=10.0.0.5 bash sync_guild_strategies.sh
#
# Required:
#   REALM       Realm ID: 1=vanilla, 2=tbc, 3=wotlk
#   DB_PASS     MariaDB/MySQL password
#
# Optional:
#   DB_HOST          Default: 127.0.0.1
#   DB_PORT          Default: 3306
#   DB_USER          Default: root
#   GUILD_JSON_BASE  Base path to jsons/guilds/. Default: auto-detected relative to script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUILD_JSON_BASE="${GUILD_JSON_BASE:-${SCRIPT_DIR}/../../spp-web/jsons/guilds}"

REALM="${REALM:-}"
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASS="${DB_PASS:-}"

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
}

require_var() {
  if [[ -z "${!1:-}" ]]; then
    echo "ERROR: Required variable '$1' is not set." >&2
    usage >&2
    exit 1
  fi
}

require_var REALM
require_var DB_PASS

case "$REALM" in
  1) DB="classiccharacters" ;;
  2) DB="tbccharacters"     ;;
  3) DB="wotlkcharacters"   ;;
  *) echo "ERROR: Unknown REALM '$REALM'. Must be 1, 2, or 3." >&2; exit 1 ;;
esac

JSON_FILE="${GUILD_JSON_BASE}/realm-${REALM}/guilds.json"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "ERROR: JSON file not found: $JSON_FILE — run scan_guilds.sh first." >&2
  exit 1
fi

command -v jq >/dev/null || { echo "ERROR: jq is required but not installed." >&2; exit 1; }

mysql_cmd() {
  MYSQL_PWD="$DB_PASS" mysql \
    --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
    --batch --skip-column-names "$@"
}

mysql_exec() {
  MYSQL_PWD="$DB_PASS" mysql \
    --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
    "$DB" <<< "$1"
}

# ── Strategy flavor profiles ──────────────────────────────────────────────────
# Edit these to tune bot behavior per archetype.
# Keys map to the "flavor" field in guilds.json.
# "default" flavor = no override (bots use global RandomBotStrategies from conf).
declare -A FLAVOR_CO FLAVOR_NC FLAVOR_REACT

FLAVOR_CO[leveling]="+dps,+dps assist,-threat,+custom::say"
FLAVOR_NC[leveling]="+rpg,+quest,+grind,+loot,+wander,+custom::say"
FLAVOR_REACT[leveling]=""

FLAVOR_CO[quest]="+dps,+dps assist,-threat,+custom::say"
FLAVOR_NC[quest]="+rpg,+rpg quest,+loot,+tfish,+wander,+custom::say"
FLAVOR_REACT[quest]=""

FLAVOR_CO[pvp]="+dps,+dps assist,+threat,+boost,+pvp,+duel,+custom::say"
FLAVOR_NC[pvp]="+rpg,+wander,+bg,+custom::say"
FLAVOR_REACT[pvp]="+pvp"

FLAVOR_CO[farming]="+dps,-threat"
FLAVOR_NC[farming]="+gather,+grind,+loot,+tfish,+wander,+rpg maintenance"
FLAVOR_REACT[farming]=""
# ─────────────────────────────────────────────────────────────────────────────

guilds_json=$(cat "$JSON_FILE")
guild_count=$(echo "$guilds_json" | jq '.guilds | length')

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Syncing realm $REALM ($DB) — $guild_count guilds..."

total_removed=0
total_written=0

while IFS= read -r guild_entry; do
  guild_id=$(echo "$guild_entry" | jq -r '.guild_id')
  guild_name=$(echo "$guild_entry" | jq -r '.name')
  flavor=$(echo "$guild_entry" | jq -r '.flavor // "default"')

  # Get current guild member GUIDs from DB
  member_guids=$(mysql_cmd "$DB" \
    <<< "SELECT guid FROM guild_member WHERE guildid = ${guild_id};" \
    | tr '\n' ',' | sed 's/,$//')

  if [[ -z "$member_guids" ]]; then
    echo "  Guild #$guild_id '$guild_name' — no members in DB, skipping."
    continue
  fi

  # Step 1: Remove existing override rows for all current members
  removed=$(mysql_cmd "$DB" \
    <<< "SELECT COUNT(*) FROM ai_playerbot_db_store WHERE guid IN (${member_guids}) AND preset = '';" \
    | tr -d '[:space:]')

  mysql_exec "DELETE FROM ai_playerbot_db_store WHERE guid IN (${member_guids}) AND preset = '';"
  total_removed=$(( total_removed + removed ))

  if [[ "$flavor" == "default" ]]; then
    echo "  Guild #$guild_id '$guild_name' (default) — cleared $removed override rows."
    continue
  fi

  # Step 2: Validate flavor is known
  if [[ -z "${FLAVOR_CO[$flavor]+x}" ]]; then
    echo "  WARNING: Guild #$guild_id '$guild_name' has unknown flavor '$flavor' — skipping write." >&2
    continue
  fi

  # Step 3: Insert flavor rows for each member
  co="${FLAVOR_CO[$flavor]}"
  nc="${FLAVOR_NC[$flavor]}"
  react="${FLAVOR_REACT[$flavor]}"

  # Build batch INSERT
  sql="INSERT INTO ai_playerbot_db_store (guid, preset, \`key\`, value) VALUES"
  rows=""
  while IFS=',' read -ra guids_arr; do
    for guid in "${guids_arr[@]}"; do
      guid="${guid// /}"
      [[ -z "$guid" ]] && continue
      # Escape single quotes in strategy strings (precaution)
      co_esc="${co//\'/\'\'}"
      nc_esc="${nc//\'/\'\'}"
      rows+=" ($guid, '', 'co', '$co_esc'),"
      rows+=" ($guid, '', 'nc', '$nc_esc'),"
      if [[ -n "$react" ]]; then
        react_esc="${react//\'/\'\'}"
        rows+=" ($guid, '', 'react', '$react_esc'),"
      fi
    done
  done <<< "$member_guids"

  if [[ -n "$rows" ]]; then
    rows="${rows%,}"  # strip trailing comma
    mysql_exec "${sql}${rows};"
    member_count=$(echo "$member_guids" | tr ',' '\n' | grep -c '[0-9]' || true)
    total_written=$(( total_written + member_count ))
    echo "  Guild #$guild_id '$guild_name' [$flavor] — $member_count members updated."
  fi

done < <(echo "$guilds_json" | jq -c '.guilds[]')

echo "Done. $total_removed old rows removed, $total_written bots updated."
echo "Bots will load new strategies on next relog (cycle takes ~10-30 min)."
