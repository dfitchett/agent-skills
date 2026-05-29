#!/usr/bin/env bash
#
# prompt-target.sh — ask a Slack target (group DM or channel) a question and wait for the first reply.
#
# Target may be:
#   - A comma-separated list of workspace handles (e.g. "derek.fitchett,yinka"):
#     opens a multi-person DM (mpim) and polls its history.
#   - A channel name (e.g. "#bmt-team-2") or channel ID (e.g. "C0123ABCD" / "G0123ABCD"):
#     posts the prompt in the channel and polls for thread replies.
#
# Auto-detects target type by format. Override with --target-type if needed.
#
# Outputs the decoded reply text to stdout (Slack HTML entities decoded).
# Exits 0 on success, 1 on timeout, 2 on config/auth error.
#
# Required bot scopes:
#   Always: chat:write, users:read
#   Handles mode: mpim:write, mpim:history, im:write, im:history
#   Channel mode: chat:write.public (to post in channels the bot isn't a member of),
#                 channels:history (public) and/or groups:history (private),
#                 conversations.replies uses the same history scopes.
#                 The bot must also be a member of any private channel.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: prompt-target.sh \
  --token <xoxb-...> \
  --target <handles CSV, #channel-name, or C-channel-ID> \
  --question <prompt text> \
  [--target-type handles|channel] \
  [--wait-minutes <int, default 15>] \
  [--poll-interval <int seconds, default 30>] \
  [--followup <text posted on timeout; omit for none>]

Auto-detection: leading "#" or pattern "C[A-Z0-9]+"/"G[A-Z0-9]+" -> channel mode;
anything else -> handles mode (treated as comma-separated workspace handles).

Outputs the first reply (HTML-decoded) to stdout. In channel mode, the prompt is
posted in the channel and the bot polls for thread replies; in handles mode, it
opens an mpim and polls its history.
USAGE
}

# --- arg parsing ---
TOKEN=""
TARGET=""
QUESTION=""
TARGET_TYPE=""
WAIT_MINUTES=15
POLL_INTERVAL=30
FOLLOWUP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token)         TOKEN="$2"; shift 2 ;;
    --target)        TARGET="$2"; shift 2 ;;
    --question)      QUESTION="$2"; shift 2 ;;
    --target-type)   TARGET_TYPE="$2"; shift 2 ;;
    --wait-minutes)  WAIT_MINUTES="$2"; shift 2 ;;
    --poll-interval) POLL_INTERVAL="$2"; shift 2 ;;
    --followup)      FOLLOWUP="$2"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for v in TOKEN TARGET QUESTION; do
  if [ -z "${!v}" ]; then echo "Missing required arg: --${v,,}" >&2; usage >&2; exit 2; fi
done

# Auto-detect target type
if [ -z "$TARGET_TYPE" ]; then
  if [[ "$TARGET" == \#* ]] || [[ "$TARGET" =~ ^[CG][A-Z0-9]+$ ]]; then
    TARGET_TYPE="channel"
  else
    TARGET_TYPE="handles"
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

slack_api() {
  local method="$1"; shift
  if [[ "$method" == *".list" || "$method" == *".history" || "$method" == *".replies" || "$method" == "conversations.info" ]]; then
    curl -s -G "https://slack.com/api/${method}" \
      -H "Authorization: Bearer ${TOKEN}" "$@"
  else
    curl -s -X POST "https://slack.com/api/${method}" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" "$@"
  fi
}

# 1. Auth check
auth_json=$(slack_api auth.test)
if [ "$(jq -r '.ok' <<<"$auth_json")" != "true" ]; then
  echo "auth.test failed: $(jq -r '.error // "unknown"' <<<"$auth_json")" >&2
  exit 2
fi
BOT_USER_ID=$(jq -r '.user_id' <<<"$auth_json")

# 2. Resolve target → POST_CHANNEL (where we post the question)
POST_CHANNEL=""
THREAD_PARENT=""  # set in channel mode to scope polling to thread replies

if [ "$TARGET_TYPE" = "handles" ]; then
  # Paginated users.list lookup, then conversations.open
  cursor=""
  > "$WORK/all-users.jsonl"
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

  IFS=',' read -ra HANDLES <<<"$TARGET"
  USER_IDS=()
  for raw in "${HANDLES[@]}"; do
    handle="${raw#@}"
    handle="$(echo "$handle" | xargs)"
    matches=$(jq -r --arg h "$handle" 'select((.name // "" | ascii_downcase) == ($h | ascii_downcase)) | .id' "$WORK/all-users.jsonl")
    count=$(echo "$matches" | grep -c . || true)
    if [ "$count" -eq 0 ]; then
      echo "Could not resolve handle \"$raw\" — no matching workspace user." >&2; exit 2
    elif [ "$count" -gt 1 ]; then
      echo "Could not uniquely resolve handle \"$raw\" — matched $count users." >&2; exit 2
    fi
    USER_IDS+=("$matches")
  done

  USERS_CSV=$(IFS=,; echo "${USER_IDS[*]}")
  open_resp=$(slack_api conversations.open --data "{\"users\": \"${USERS_CSV}\"}")
  if [ "$(jq -r '.ok' <<<"$open_resp")" != "true" ]; then
    echo "conversations.open failed: $(jq -r '.error // "unknown"' <<<"$open_resp")" >&2
    exit 2
  fi
  POST_CHANNEL=$(jq -r '.channel.id' <<<"$open_resp")
else
  # Channel mode: resolve name → ID if needed
  if [[ "$TARGET" == \#* ]]; then
    name="${TARGET#\#}"
    cursor=""
    while :; do
      if [ -z "$cursor" ]; then
        slack_api conversations.list --data-urlencode "limit=200" --data-urlencode "types=public_channel,private_channel" > "$WORK/chan-page.json"
      else
        slack_api conversations.list --data-urlencode "limit=200" --data-urlencode "cursor=${cursor}" --data-urlencode "types=public_channel,private_channel" > "$WORK/chan-page.json"
      fi
      if [ "$(jq -r '.ok' "$WORK/chan-page.json")" != "true" ]; then
        echo "conversations.list failed: $(jq -r '.error // "unknown"' "$WORK/chan-page.json")" >&2; exit 2
      fi
      cid=$(jq -r --arg n "$name" '.channels[]? | select(.name == $n) | .id' "$WORK/chan-page.json")
      if [ -n "$cid" ]; then POST_CHANNEL="$cid"; break; fi
      cursor=$(jq -r '.response_metadata.next_cursor // ""' "$WORK/chan-page.json")
      [ -z "$cursor" ] && break
    done
    if [ -z "$POST_CHANNEL" ]; then echo "Could not resolve channel \"#${name}\"" >&2; exit 2; fi
  else
    POST_CHANNEL="$TARGET"
  fi
fi

# 3. Post the question
jq -n --arg channel "$POST_CHANNEL" --arg text "$QUESTION" \
  '{channel: $channel, unfurl_links: false, text: $text}' > "$WORK/q-payload.json"

post_resp=$(slack_api chat.postMessage --data @"$WORK/q-payload.json")
if [ "$(jq -r '.ok' <<<"$post_resp")" != "true" ]; then
  echo "chat.postMessage (question) failed: $(jq -r '.error // "unknown"' <<<"$post_resp")" >&2
  exit 2
fi
PROMPT_TS=$(jq -r '.ts' <<<"$post_resp")
if [ "$TARGET_TYPE" = "channel" ]; then THREAD_PARENT="$PROMPT_TS"; fi

# 4. Poll for reply
max_iter=$(( WAIT_MINUTES * 60 / POLL_INTERVAL ))
i=0
reply_raw=""
while [ "$i" -lt "$max_iter" ]; do
  i=$((i+1))

  if [ -n "$THREAD_PARENT" ]; then
    # Channel mode: pull thread replies
    slack_api conversations.replies \
      --data-urlencode "channel=${POST_CHANNEL}" \
      --data-urlencode "ts=${THREAD_PARENT}" \
      --data-urlencode "limit=20" > "$WORK/history.json"
    reply_raw=$(jq -r --arg bot "$BOT_USER_ID" --arg parent "$THREAD_PARENT" \
      '[.messages[]? | select(.user != $bot and .ts != $parent and (.text // "") != "")] | sort_by(.ts) | .[0] // empty | .text' \
      "$WORK/history.json")
  else
    # mpim mode: pull DM history newer than the prompt
    slack_api conversations.history \
      --data-urlencode "channel=${POST_CHANNEL}" \
      --data-urlencode "oldest=${PROMPT_TS}" \
      --data-urlencode "limit=20" > "$WORK/history.json"
    reply_raw=$(jq -r --arg bot "$BOT_USER_ID" \
      '[.messages[]? | select(.user != $bot and (.text // "") != "")] | sort_by(.ts) | .[0] // empty | .text' \
      "$WORK/history.json")
  fi

  if [ -n "$reply_raw" ] && [ "$reply_raw" != "null" ]; then break; fi
  reply_raw=""
  sleep "$POLL_INTERVAL"
done

# 5. Timeout
if [ -z "$reply_raw" ]; then
  if [ -n "$FOLLOWUP" ]; then
    if [ -n "$THREAD_PARENT" ]; then
      jq -n --arg channel "$POST_CHANNEL" --arg ts "$THREAD_PARENT" --arg text "$FOLLOWUP" \
        '{channel: $channel, thread_ts: $ts, unfurl_links: false, text: $text}' > "$WORK/followup.json"
    else
      jq -n --arg channel "$POST_CHANNEL" --arg text "$FOLLOWUP" \
        '{channel: $channel, unfurl_links: false, text: $text}' > "$WORK/followup.json"
    fi
    slack_api chat.postMessage --data @"$WORK/followup.json" > /dev/null
  fi
  echo "Timed out after ${WAIT_MINUTES} min waiting for reply." >&2
  exit 1
fi

# 6. Decode Slack HTML entities and emit
decoded=$(echo "$reply_raw" | sed -e 's/&amp;/\&/g' -e 's/&lt;/</g' -e 's/&gt;/>/g')
echo "$decoded"
