#!/usr/bin/env bash
#
# post-recap.sh — post a single, fully-assembled recap message to a Slack channel.
#
# Posts exactly once via chat.postMessage. The message body is read from a file
# (--text-file) so arbitrary characters (&, *, backticks, newlines) survive without
# shell-escaping bugs. Prints the message ts to stdout on success.
#
# Exits 0 on success, 1 on any Slack API failure, 2 on config error.
#
# This script intentionally does NOT edit, retry, or post more than once. The recap
# is assembled fully (password + recording + summary) before this is called, so a
# single post is all that's needed.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: post-recap.sh \
  --token <xoxb-...> \
  --channel <channel name or ID, e.g. "staff-test" or "C0123ABCD"> \
  --text-file <path to a UTF-8 file containing the Slack mrkdwn message body>

Prints the posted message's ts to stdout on success.
USAGE
}

TOKEN=""
CHANNEL=""
TEXT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token)     TOKEN="$2"; shift 2 ;;
    --channel)   CHANNEL="$2"; shift 2 ;;
    --text-file) TEXT_FILE="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for v in TOKEN CHANNEL TEXT_FILE; do
  if [ -z "${!v}" ]; then echo "Missing required arg: --${v,,}" >&2; usage >&2; exit 2; fi
done

if [ ! -r "$TEXT_FILE" ]; then
  echo "Text file not readable: $TEXT_FILE" >&2
  exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build the JSON payload with jq so the message body is escaped correctly regardless
# of its contents. --rawfile reads the whole file as a single string.
jq -n \
  --arg channel "$CHANNEL" \
  --rawfile text "$TEXT_FILE" \
  '{channel: $channel, text: $text, unfurl_links: false, unfurl_media: false}' \
  > "$WORK/payload.json"

resp=$(curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data @"$WORK/payload.json")

if [ "$(jq -r '.ok' <<<"$resp")" != "true" ]; then
  echo "chat.postMessage failed: $(jq -r '.error // "unknown"' <<<"$resp")" >&2
  exit 1
fi

jq -r '.ts' <<<"$resp"
