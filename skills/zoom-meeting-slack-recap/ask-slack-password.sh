#!/usr/bin/env bash
#
# ask-slack-password.sh — DM a Slack group with a password prompt and wait for the first reply.
#
# Outputs the decoded password to stdout on success.
# Exits 0 on success, 1 on timeout (no reply in window), 2 on config/auth error.
#
# All Slack API calls go through curl; jq parses JSON. Pure Bash otherwise.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ask-slack-password.sh \
  --token <xoxb-...> \
  --handles <comma-separated handles, e.g. "derek.fitchett,yinka"> \
  --meeting-title <text> \
  --meeting-date <text> \
  --recap-channel <channel name> \
  [--wait-minutes <int, default 15>] \
  [--poll-interval <int seconds, default 30>]

Outputs the captured password to stdout, with Slack HTML entities decoded.
USAGE
}

# --- arg parsing ---
TOKEN=""
HANDLES_RAW=""
MEETING_TITLE=""
MEETING_DATE=""
RECAP_CHANNEL=""
WAIT_MINUTES=15
POLL_INTERVAL=30

while [ $# -gt 0 ]; do
  case "$1" in
    --token)         TOKEN="$2"; shift 2 ;;
    --handles)       HANDLES_RAW="$2"; shift 2 ;;
    --meeting-title) MEETING_TITLE="$2"; shift 2 ;;
    --meeting-date)  MEETING_DATE="$2"; shift 2 ;;
    --recap-channel) RECAP_CHANNEL="$2"; shift 2 ;;
    --wait-minutes)  WAIT_MINUTES="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for v in TOKEN HANDLES_RAW MEETING_TITLE MEETING_DATE RECAP_CHANNEL; do
  if [ -z "${!v}" ]; then echo "Missing required arg: --${v,,}" >&2; usage >&2; exit 2; fi
done

# Workdir for transient state
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

slack_api() {
  # slack_api <method> <args...>
  # GET if method matches "*.list" or "*.history"; POST otherwise.
  local method="$1"; shift
  if [[ "$method" == *".list" || "$method" == *".history" ]]; then
    curl -s -G "https://slack.com/api/${method}" \
      -H "Authorization: Bearer ${TOKEN}" "$@"
  else
    curl -s -X POST "https://slack.com/api/${method}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" "$@"
  fi
}

# --- 1. auth.test — confirm token + get bot's user ID ---
auth_json=$(slack_api auth.test)
if [ "$(jq -r '.ok' <<<"$auth_json")" != "true" ]; then
  echo "auth.test failed: $(jq -r '.error // "unknown"' <<<"$auth_json")" >&2
  exit 2
fi
BOT_USER_ID=$(jq -r '.user_id' <<<"$auth_json")

# --- 2. Resolve handles to user IDs ---
IFS=',' read -ra HANDLES <<<"$HANDLES_RAW"
USER_IDS=()
cursor=""
> "$WORK/all-users.json"

# Pull the entire users.list once; cache to file
while :; do
  if [ -z "$cursor" ]; then
    slack_api users.list --data-urlencode "limit=200" > "$WORK/users-page.json"
  else
    slack_api users.list --data-urlencode "limit=200" --data-urlencode "cursor=${cursor}" > "$WORK/users-page.json"
  fi
  if [ "$(jq -r '.ok' "$WORK/users-page.json")" != "true" ]; then
    echo "users.list failed: $(jq -r '.error // "unknown"' "$WORK/users-page.json")" >&2
    exit 2
  fi
  jq -c '.members[]?' "$WORK/users-page.json" >> "$WORK/all-users.jsonl"
  cursor=$(jq -r '.response_metadata.next_cursor // ""' "$WORK/users-page.json")
  [ -z "$cursor" ] && break
done

for raw in "${HANDLES[@]}"; do
  handle="${raw#@}"           # strip leading @
  handle="${handle## }"       # strip leading spaces
  handle="${handle%% }"       # strip trailing spaces
  matches=$(jq -r --arg h "$handle" 'select((.name // "" | ascii_downcase) == ($h | ascii_downcase)) | .id' "$WORK/all-users.jsonl")
  count=$(echo "$matches" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    echo "Could not resolve handle \"$raw\" — no matching workspace user." >&2
    exit 2
  elif [ "$count" -gt 1 ]; then
    echo "Could not uniquely resolve handle \"$raw\" — matched $count users." >&2
    exit 2
  fi
  USER_IDS+=("$matches")
done

USERS_CSV=$(IFS=,; echo "${USER_IDS[*]}")

# --- 3. Open DM ---
open_resp=$(slack_api conversations.open --data "{\"users\": \"${USERS_CSV}\"}")
if [ "$(jq -r '.ok' <<<"$open_resp")" != "true" ]; then
  echo "conversations.open failed: $(jq -r '.error // "unknown"' <<<"$open_resp")" >&2
  exit 2
fi
DM_CHANNEL=$(jq -r '.channel.id' <<<"$open_resp")

# --- 4. Post the prompt ---
prompt_text="👋 About to post the recap for *${MEETING_TITLE}* (held ${MEETING_DATE}) in ${RECAP_CHANNEL}.

What's the recording password? Reply with *just the password text* — first reply wins."

jq -n \
  --arg channel "$DM_CHANNEL" \
  --arg text "$prompt_text" \
  '{channel: $channel, unfurl_links: false, text: $text}' > "$WORK/prompt-payload.json"

post_resp=$(slack_api chat.postMessage --data @"$WORK/prompt-payload.json")
if [ "$(jq -r '.ok' <<<"$post_resp")" != "true" ]; then
  echo "chat.postMessage (prompt) failed: $(jq -r '.error // "unknown"' <<<"$post_resp")" >&2
  exit 2
fi
PROMPT_TS=$(jq -r '.ts' <<<"$post_resp")

# --- 5. Poll history every POLL_INTERVAL seconds, up to WAIT_MINUTES total ---
max_iter=$(( WAIT_MINUTES * 60 / POLL_INTERVAL ))
i=0
reply_raw=""
while [ "$i" -lt "$max_iter" ]; do
  i=$((i+1))
  slack_api conversations.history \
    --data-urlencode "channel=${DM_CHANNEL}" \
    --data-urlencode "oldest=${PROMPT_TS}" \
    --data-urlencode "limit=20" > "$WORK/history.json"

  reply_raw=$(jq -r --arg bot "$BOT_USER_ID" \
    '[.messages[]? | select(.user != $bot and (.text // "") != "")] | sort_by(.ts) | .[0] // empty | .text' \
    "$WORK/history.json")

  if [ -n "$reply_raw" ] && [ "$reply_raw" != "null" ]; then
    break
  fi
  reply_raw=""
  sleep "$POLL_INTERVAL"
done

if [ -z "$reply_raw" ]; then
  # Timeout — DM a follow-up so recipients know we gave up, then exit 1
  followup_text="No reply received in ${WAIT_MINUTES} min — posting the recap without a password. Reply with the password here and the recap can be edited manually."
  jq -n --arg channel "$DM_CHANNEL" --arg text "$followup_text" \
    '{channel: $channel, unfurl_links: false, text: $text}' > "$WORK/followup-payload.json"
  slack_api chat.postMessage --data @"$WORK/followup-payload.json" > /dev/null
  echo "Timed out after ${WAIT_MINUTES} min waiting for password reply." >&2
  exit 1
fi

# --- 6. Decode Slack HTML entities and emit ---
decoded=$(echo "$reply_raw" | sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g')
echo "$decoded"
