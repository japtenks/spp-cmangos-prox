#!/usr/bin/env bash
# scan_guilds.sh — Reads guild table from DB and seeds guild flavor JSON.
#
# - Adds new guilds with a randomly weighted flavor assignment.
# - Never overwrites entries where flavor_locked=true.
# - Marks guilds no longer in DB as disbanded (removes from active list).
#
# Usage:
#   REALM=1 DB_PASS=secret bash scan_guilds.sh
#   REALM=2 DB_PASS=secret DB_HOST=10.0.0.5 bash scan_guilds.sh
#
# Required:
#   REALM       Realm ID: 1=vanilla, 2=tbc, 3=wotlk
#   DB_PASS     MariaDB/MySQL password
#
# Optional:
#   DB_HOST     Default: 127.0.0.1
#   DB_PORT     Default: 3306
#   DB_USER     Default: root
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

# Map realm to DB name and JSON file
case "$REALM" in
  1) DB="classiccharacters" ;;
  2) DB="tbccharacters"     ;;
  3) DB="wotlkcharacters"   ;;
  *) echo "ERROR: Unknown REALM '$REALM'. Must be 1, 2, or 3." >&2; exit 1 ;;
esac

JSON_FILE="${GUILD_JSON_BASE}/realm-${REALM}/guilds.json"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "ERROR: JSON file not found: $JSON_FILE" >&2
  exit 1
fi

command -v jq >/dev/null || { echo "ERROR: jq is required but not installed." >&2; exit 1; }

mysql_cmd() {
  MYSQL_PWD="$DB_PASS" mysql \
    --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" \
    --batch --skip-column-names "$@"
}

# Weighted random flavor selection based on flavor_weights in JSON
pick_flavor() {
  local weights_json="$1"
  # Build array of (flavor, cumulative_weight) and pick by random
  local total
  total=$(echo "$weights_json" | jq '[to_entries[].value] | add')
  local roll=$(( RANDOM % total ))
  echo "$weights_json" | jq -r --argjson roll "$roll" '
    to_entries | reduce .[] as $e (
      {"cum": 0, "result": null};
      if .result == null and ($e.value + .cum) > $roll
      then {"cum": (.cum + $e.value), "result": $e.key}
      else {"cum": (.cum + $e.value), "result": .result}
      end
    ) | .result
  '
}

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Scanning realm $REALM ($DB)..."

# Read current JSON
current_json=$(cat "$JSON_FILE")
flavor_weights=$(echo "$current_json" | jq '.flavor_weights')

# Query all current guilds from DB
db_guilds=$(mysql_cmd "$DB" <<'SQL'
SELECT guildid, name, leaderguid,
       DATE_FORMAT(CreateDate, '%Y-%m-%dT%H:%i:%SZ')
FROM guild
ORDER BY guildid;
SQL
)

# Build map of existing guild_ids in JSON (locked + unlocked)
existing_ids=$(echo "$current_json" | jq '[.guilds[].guild_id]')

updated_guilds="[]"

# Process each DB guild
while IFS=$'\t' read -r guild_id name leader_guid formed; do
  # Check if already in JSON
  existing=$(echo "$current_json" | jq --argjson id "$guild_id" '.guilds[] | select(.guild_id == $id)')

  if [[ -n "$existing" ]]; then
    # Already tracked — preserve as-is (respects flavor_locked)
    updated_guilds=$(echo "$updated_guilds" | jq --argjson entry "$existing" '. + [$entry]')
  else
    # New guild — assign random flavor
    flavor=$(pick_flavor "$flavor_weights")
    new_entry=$(jq -n \
      --argjson guild_id "$guild_id" \
      --arg name "$name" \
      --argjson leader_guid "$leader_guid" \
      --arg formed "${formed:-}" \
      --arg flavor "$flavor" \
      '{guild_id: $guild_id, name: $name, leader_guid: $leader_guid,
        formed: $formed, flavor: $flavor, flavor_locked: false}')
    updated_guilds=$(echo "$updated_guilds" | jq --argjson entry "$new_entry" '. + [$entry]')
    echo "  + New guild #$guild_id '$name' → flavor: $flavor"
  fi
done <<< "$db_guilds"

# Write updated JSON
updated_json=$(echo "$current_json" | jq \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson guilds "$updated_guilds" \
  '.last_updated = $ts | .guilds = $guilds')

echo "$updated_json" > "$JSON_FILE"

total=$(echo "$updated_guilds" | jq 'length')
new_count=$(echo "$updated_guilds" | jq '[.[] | select(.flavor != "default")] | length')
echo "Done. $total guilds tracked, $new_count with non-default flavor."
echo "JSON written to: $JSON_FILE"
