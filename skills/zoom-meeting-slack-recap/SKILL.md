---
name: zoom-meeting-slack-recap
description: Post a Zoom meeting recap (TLDR, summary link, recording link, password) to a Slack channel via a Slack bot. Designed to be invoked from a cron-scheduled routine that fires ~30 min after a recurring meeting ends. Pulls the most recent Zoom recording, then prompts a configurable Slack target (group of handles or a channel) for any missing details — the recording password if needed, the presenter's Slack handle for crediting, and the TLDR text itself when neither Zoom's AI summary nor the transcript yields a usable one — and posts the assembled recap exactly once. Use when the user says "post the meeting recap to Slack", "publish the Zoom summary", "/zoom-meeting-slack-recap", or wires up a new recurring-meeting routine.
---

# Zoom Meeting Slack Recap

Post a Slack message recapping a recent Zoom meeting: TLDR, full-summary link, recording link, and (optionally) password.

This skill expects to run inside a **cron-scheduled routine**. One routine per recurring meeting, scheduled ~30 minutes after the meeting ends. The routine's prompt carries the meeting-specific inputs.

Rotating or missing details — the recording password, the presenter's Slack handle for crediting in the TLDR, and the TLDR text itself when neither AI summary nor transcript is available — are **not** baked into the routine. Instead, the skill asks a configurable Slack target (`prompt_target`: either a group of handles via DM or a single channel via threaded reply) and uses the first reply. This avoids storing values in the routine config that change per session.

**Single-post guarantee:** the skill gathers everything it needs — password, recording link, and a TLDR — *before* it posts anything to the recap channel. It posts the recap exactly once. There is no "post a placeholder then edit it" behavior. The TLDR is sourced in strict priority order: Zoom AI Companion summary → transcript-derived summary → asking `prompt_target` for it directly. The only Slack messages sent before the final recap are the prompts to `prompt_target` for whatever's missing (and a follow-up note if a prompt times out).

## Required inputs

The invoking routine prompt must supply:

| Field | Description |
|---|---|
| `meeting_id_or_title` | Either an exact Zoom meeting topic (e.g. `"BMT Team 2 Standup"`) or a numeric Zoom meeting ID. Used to locate the most recent recording. |
| `slack_channel` | Channel name (e.g. `#bmt-team-2`) or channel ID (e.g. `C0123ABCDEF`) — where the recap is posted. The bot must already be a member. |
| `slack_bot_token` | A Slack bot token (`xoxb-...`). See **Required bot scopes** below. |
| `password_protected` *(optional)* | Boolean. `true` (default) means the Zoom recording requires a password to view — the skill will prompt `prompt_target` to collect it. Set to `false` for unprotected recordings; the skill skips the password prompt entirely and the recap omits the password line. |
| `prompt_target` | Where the skill should ask the human(s) for missing information. Accepts **either** an array of Slack handles (e.g. `["@derek-fitchett", "@yinka"]`) — opens a multi-person DM and polls it — **or** a single channel name (e.g. `"#bmt-team-2"`) or channel ID (e.g. `"C0123ABCD"`) — posts the question in the channel and polls the resulting thread for the first reply. Used for up to three prompts per run: recording password (if `password_protected: true`), presenter's Slack handle (when the skill is generating the TLDR), and the TLDR text (when neither AI summary nor transcript is available). Handles must match the Slack workspace's `name` field, not display names. Channel mode requires the additional bot scopes noted below; the bot must also be in the channel (or have `chat:write.public` for public channels). |
| `prompt_wait_minutes` *(optional)* | How long to wait for a reply at each prompt before falling back. Defaults to `15`. Applies to every prompt the skill issues. |
| `stale_recording_threshold_hours` *(optional)* | If the matched Zoom recording's start time is older than this many hours, exit silently without prompting anyone or posting. Defaults to `4`. Increase for meetings whose recordings frequently take longer to surface, or decrease to be stricter about canceled-meeting noise. |
| `header_phrasing` *(optional)* | Template for the first line of the recap. Use the placeholder `{title}` for the Zoom meeting topic. Defaults to `"{title} Recap!"`. Example overrides: `"📝 {title} — Summary"`, `"Recap of {title}"`, `"{title} debrief"`. |
| `custom_note` *(optional)* | One-liner prepended above the message body in the recap (e.g. `"Recap for folks who missed today's sync"`). |
| `footer_cta` *(optional)* | Slack-mrkdwn text appended at the bottom of the recap, after the password line, as a call-to-action (e.g. a link inviting future presenters to submit topics). Use Slack link syntax `<url\|display text>` for any links. Separated from the password line by a blank line. Omit for no footer. |

If any required field is missing, stop and report which — do not guess.

## Required bot scopes

The Slack app powering this skill needs these OAuth bot scopes:

**Always required:**
- `chat:write` — post the recap and any prompts
- `users:read` — resolve `@handle` strings to user IDs (used for handles-mode `prompt_target` and for resolving the presenter's handle when generating the TLDR)

**Required if `prompt_target` uses handles mode:**
- `mpim:write` — open a multi-person DM with the prompt recipients
- `mpim:history` — poll the DM for replies
- `im:write`, `im:history` — same, for the 1-recipient case (Slack uses a 1:1 DM)

**Required if `prompt_target` uses channel mode:**
- `chat:write.public` — post the prompt in a public channel the bot isn't a member of
- `channels:history` — read public-channel thread replies via `conversations.replies`
- `groups:history` — same, for private channels (the bot must also be invited)

If the bot is missing any scope at runtime, the relevant Slack API call returns `missing_scope` with a list — surface that error verbatim so the user can fix it in the Slack app config and reinstall.

## Workflow

### 1. Locate the meeting's most recent recording

Use the Zoom MCP connector. Prefer these tools in order:

1. **`recordings_list`** — list recordings for the authenticated user, newest first. Match on `topic` against `meeting_id_or_title` (case-insensitive, exact match) OR on numeric meeting ID.
2. **`search_meetings`** — fallback if `recordings_list` doesn't surface a match (e.g. for a non-host's meeting).

You're looking for the *most recent* recording whose topic or meeting ID matches the input. Capture:

- `start_time` (UTC timestamp of when the recording started)
- `duration` (in minutes)
- Recording share URL (the `share_url` or `play_url` field)
- Meeting UUID — needed to fetch summary assets
- Meeting topic — used as the recap header

### 2. Apply the stale-recording guard

If the matched recording's `start_time` is **older than `stale_recording_threshold_hours` ago** (default `4`), exit silently — do not DM anyone and do not post. This prevents stale chatter when a meeting was canceled or rescheduled and the cron routine still fired.

Log a one-line note locally (e.g. "Skipping: most recent recording is N hours old (threshold: <T>h)") but don't error and don't message Slack.

### 3. Ask `prompt_target` for the recording password (if password-protected)

**If `password_protected: false`, skip this entire step.** Set `zoom_password = null` and move on. The recap will post without a 🔑 line.

Otherwise, run the bundled `prompt-target.sh` helper. It handles auth, paginated handle-to-user-ID resolution (handles mode), channel resolution (channel mode), question post, reply polling (DM history in handles mode; thread replies in channel mode), HTML-entity decoding, and timeout follow-up.

Fetch the script fresh from GitHub each run so updates propagate without redeployment:

```bash
SCRIPT=/tmp/prompt-target.sh
curl -sSfL -o "$SCRIPT" \
  https://raw.githubusercontent.com/dfitchett/agent-skills/main/skills/zoom-meeting-slack-recap/prompt-target.sh
chmod +x "$SCRIPT"

# Render prompt_target as the script expects:
#   - array of handles → comma-separated string ("derek.fitchett,yinka")
#   - channel name/ID → pass through ("#bmt-team-2" or "C0123ABCD")
PROMPT_TARGET="<rendered target>"
QUESTION="👋 About to post the recap for *${meeting_topic}* (held ${human_readable_date}) in ${slack_channel}. What's the recording password? Reply with *just the password text* — first reply wins."

zoom_password=$("$SCRIPT" \
  --token "${slack_bot_token}" \
  --target "$PROMPT_TARGET" \
  --question "$QUESTION" \
  --wait-minutes "${prompt_wait_minutes:-15}" \
  --followup "No password reply received — posting the recap without it.") \
  || zoom_password=""
```

**Script exit behavior** (same for every prompt):
- **Exit 0** → stdout = the reply text, already HTML-decoded. Use verbatim.
- **Exit 1** → no reply within `--wait-minutes`. The script has already posted the `--followup` if provided. Continue with the empty value (the routine adapts — see below).
- **Exit 2** → config/auth error (bad token, missing scope, unresolvable handle/channel). Stderr explains; abort.

If `zoom_password` is empty after this step, the recap will post without the 🔑 line.

### 4. Assemble the TLDR

The recap should carry a TLDR. Evaluate three branches in this exact priority order — fall through to the next branch only if the previous one's source is unavailable:

1. **4a** — Zoom AI Companion summary (if `meeting_summary.has_summary` is true AND the Quick recap text is non-empty)
2. **4b** — Transcript-derived TLDR (if 4a's source is missing AND a non-empty transcript can be fetched)
3. **4c** — Ask `prompt_target` for the TLDR (if BOTH 4a's summary AND 4b's transcript are unavailable)

Only one of these branches runs per execution. **Never skip to 4c if a usable summary or transcript exists.** Never skip 4c if neither exists — the routine must ask the human, not give up silently.

**4a. Zoom AI Companion summary (preferred).** Call **`get_meeting_assets`** with the meeting UUID. If `meeting_summary.has_summary` is true AND the **Quick recap** section (inside `meeting_summary.summary_markdown` / `summary_plain_text`) is non-empty:
- Ask `prompt_target` for the presenter's Slack handle (see "Asking for the presenter handle" below).
- Generate a 2–4 sentence TLDR from the Quick recap, **incorporating the presenter as a Slack mention** (`<@U…>`) wherever it makes sense (typically the lead clause: `*<@U123>* presented …`).
- `summary_doc_url` = the summary document link Zoom returns (for the 📄 line).
- Status note: `Zoom AI summary`.

Otherwise (summary not ready or empty), fall through to 4b.

**4b. Transcript-derived TLDR (fallback).** Attempt to fetch a transcript via `get_meeting_assets` (look at `meeting_transcript.transcript_items`) or `get_recording_resource` (look at the `transcripts` array). The transcript counts as available only if it contains substantive text — a missing field, an empty array, or just speaker greetings doesn't count. If a usable transcript exists:
- Ask `prompt_target` for the presenter's Slack handle.
- Read the transcript and **write a 2–4 sentence TLDR yourself** that captures the key decisions, outcomes, and action items, with the presenter mentioned as `<@U…>` where it fits.
- No `summary_doc_url` in this branch — the 📄 line is omitted.
- Status note: `transcript-derived TLDR`.

Otherwise (no usable transcript either), fall through to 4c.

**4c. Ask `prompt_target` for the TLDR directly (last resort, REQUIRED when 4a and 4b both fail).** When neither a Zoom AI summary NOR a usable transcript exists (e.g. recording still processing audio, or AI Companion wasn't enabled, or transcript permission missing), the routine **must** prompt the human via `prompt_target` rather than posting a TLDR-less recap. Do not skip this step:

```bash
QUESTION="🧠 I couldn't find a Zoom AI summary or transcript for *${meeting_topic}* (held ${human_readable_date}). What should the TLDR for the recap in ${slack_channel} say? Reply with the TLDR text — first reply wins."

tldr=$("$SCRIPT" \
  --token "${slack_bot_token}" \
  --target "$PROMPT_TARGET" \
  --question "$QUESTION" \
  --wait-minutes "${prompt_wait_minutes:-15}" \
  --followup "No TLDR reply received — posting the recap without a TLDR block.") \
  || tldr=""
```

The reply text is the TLDR verbatim (treat any `<@U…>` mentions the user includes as intentional). No presenter prompt in this branch — the user-supplied TLDR text is final. If `tldr` is empty (timeout), post without the TLDR block. Status note: `user-supplied TLDR` (or `no TLDR available` on timeout).

#### Asking for the presenter handle (used by 4a and 4b)

```bash
QUESTION="🎤 Who presented at *${meeting_topic}* on ${human_readable_date}? Reply with their Slack handle (e.g. \`@aaron.ponce\`) so I can mention them in the recap. Reply \`none\` if there was no single presenter."

presenter_reply=$("$SCRIPT" \
  --token "${slack_bot_token}" \
  --target "$PROMPT_TARGET" \
  --question "$QUESTION" \
  --wait-minutes "${prompt_wait_minutes:-15}" \
  --followup "No presenter handle reply — generating TLDR without an @-mention.") \
  || presenter_reply=""
```

**Resolving the reply to a user ID:**
- If `presenter_reply` is empty, `none`, `n/a`, or `-` (case-insensitive): skip the mention.
- If it contains `<@U…>` (a real Slack mention pasted by the replier): extract the user ID with `grep -oE '<@U[A-Z0-9]+>'`.
- Otherwise: strip leading `@`, lowercase, look up via paginated `users.list` matching the `.name` field. Fail soft — if no unique match, log a note and skip the mention rather than aborting.

Once resolved, the presenter's `<@U…>` is substituted into the generated TLDR before assembling the message.

### 5. Build and post the recap — exactly once

Assemble the full message body, write it to a temp file, and post it **one time** with the bundled `post-recap.sh` helper. Do not call `chat.postMessage` directly, and never post more than once.

#### Message format

```
*<header_phrasing with {title} substituted>*
[custom_note line, if provided]
*Meeting:* <day> <month> <day>, <year> — <h:mm AM/PM> ET / <h:mm AM/PM> PT (<duration> min)

*TLDR:* <tldr from step 4>               ← omit this block only if step 4 produced no TLDR

📄 <summary_doc_url|*Full summary*>      ← omit if no summary_doc_url (e.g. transcript-derived TLDR)
🎥 <recording-share-url|*Recording*>
🔑 *Password:* `<zoom_password>`         ← omit if password is null (`password_protected: false`, or prompt timed out)

<footer_cta text, verbatim>              ← omit entire block (including blank line above) if footer_cta is empty
```

Slack link syntax: `<url|display text>` makes the display text clickable while hiding the raw URL. Wrap the password in backticks so characters like `*` or `&` don't trigger Slack formatting.

**Header:** Substitute `{title}` in `header_phrasing` with the Zoom meeting's `topic` field. Default `"{title} Recap!"` yields e.g. `*Engineering CoP Recap!*`.

**Meeting line / timezone handling:** Convert the recording's UTC `start_time` to both Eastern and Pacific local times and show them on one line — e.g. `Thu May 14, 2026 — 3:56 PM ET / 12:56 PM PT (34 min)`. Use `date -d "<start_time>" -u` plus `TZ=America/New_York date -d "..."` and `TZ=America/Los_Angeles date -d "..."` (or `TZ=… date -j -f` on macOS) to compute each.

#### Posting

Write the assembled body to a file, then post once:

```bash
RECAP_FILE=$(mktemp)
cat > "$RECAP_FILE" <<'BODY'
<the assembled message text>
BODY

ts=$(/path/to/post-recap.sh \
  --token "${slack_bot_token}" \
  --channel "${slack_channel}" \
  --text-file "$RECAP_FILE")
```

`post-recap.sh` builds the JSON with `jq --rawfile`, so any characters in the body (`&`, `*`, backticks, newlines) are escaped safely — write the literal message, don't pre-escape. It posts exactly once and prints the message `ts` on success (exit 0), or an error on stderr (exit 1 = Slack API failure, exit 2 = config error).

For a local routine, reference the script at its on-disk path. For a remote routine, fetch it first the same way as `prompt-target.sh`:

```bash
curl -sSfL -o /tmp/post-recap.sh \
  https://raw.githubusercontent.com/dfitchett/agent-skills/main/skills/zoom-meeting-slack-recap/post-recap.sh
chmod +x /tmp/post-recap.sh
```

### 6. Report what happened

End the routine with a one-line status:

- `Posted recap to <channel> (ts=<ts>); Zoom AI summary; presenter <@U…>; password from <handle> in <N>s` — happy path, AI summary + presenter + password
- `Posted recap to <channel> (ts=<ts>); transcript-derived TLDR; presenter <@U…>; password from <handle>` — AI summary wasn't ready, TLDR generated from transcript
- `Posted recap to <channel> (ts=<ts>); user-supplied TLDR; password from <handle>` — neither AI summary nor transcript existed; TLDR came from a `prompt_target` reply
- `Posted recap to <channel> (ts=<ts>); no password required` — `password_protected: false`
- `Posted recap to <channel> without password (ts=<ts>); password prompt timed out` — no reply to the password question within `prompt_wait_minutes`
- `Posted recap to <channel> with no presenter mention (ts=<ts>); presenter prompt timed out` — TLDR generated without the `<@…>` mention
- `Posted recap to <channel> without TLDR (ts=<ts>); TLDR prompt timed out` — no summary, no transcript, and no reply to the TLDR question
- `Skipped: most recent recording is <N>h old (threshold: <T>h)` — stale guard fired (no prompts sent)
- `Failed: <reason>` — anything else

## Setting up a new recurring routine

To wire up the first routine that uses this skill:

1. **Create a Slack app** (one-time) at https://api.slack.com/apps:
   - "From scratch" → name it → pick your workspace
   - Under **OAuth & Permissions**, add **all bot scopes** listed in the "Required bot scopes" section above
   - Under **App Home → Show Tabs**, enable **Messages Tab** AND check **"Allow users to send Slash commands and messages from the messages tab"**. Without this, recipients see "Sending messages to this app has been turned off" when they try to reply to a DM prompt in handles mode, and polling will time out. (Only required for handles-mode `prompt_target`; channel-mode prompts post in a regular channel and replies go in-thread.)
   - Install to workspace → copy the `xoxb-…` token
   - `/invite @<bot-name>` in every channel the bot needs to post in
   - For each `prompt_target` recipient (handles mode), no special setup is needed beyond the bot being installed in the workspace. For channel mode, invite the bot to the prompt channel.

2. **Identify the meeting**: confirm the exact Zoom topic string or numeric ID by checking one prior recording via the Zoom MCP. Mismatches here cause the skill to silently skip.

3. **Decide on a `prompt_target`**: either (a) a list of Slack handles for a group DM (e.g. `["derek.fitchett"]`) or (b) a channel name/ID for a public thread (e.g. `"#engineering-cop"`). For each handle, in Slack click the person's profile → look for `@<handle>` under their display name (lowercase, dotted).

4. **Pick the cron expression**: schedule for ~30 minutes after the meeting's typical end time. Example for an 11:00 AM ET Tuesday meeting that runs until ~11:30:

   - `30 16 * * 2` *(11:30 AM ET → 16:30 UTC during EDT)*
   - Confirm timezone handling with your routine runner — some use UTC, some use local

5. **Create the routine** using `/schedule` (or `mcp__scheduled-tasks__create_scheduled_task`). The routine prompt should look like:

   ```
   Run the zoom-meeting-slack-recap skill for the Engineering CoP meeting.

   Skill: https://raw.githubusercontent.com/dfitchett/agent-skills/main/skills/zoom-meeting-slack-recap/SKILL.md
   Fetch via WebFetch (or curl), read it first, then follow its workflow end-to-end.

   Inputs:
   - meeting_id_or_title: "Engineering CoP"
   - slack_channel: "#staff-test"
   - slack_bot_token: pass to bash as the literal string "$RECAP_BOT_TOKEN" — never substitute or log the value
   - prompt_target: ["derek.fitchett"]                                     # OR a channel like "#engineering-cop"
   - prompt_wait_minutes: 15
   # - password_protected: true                                            # set false to skip the password prompt
   # - stale_recording_threshold_hours: 4                                  # override the default
   # - header_phrasing: "{title} Recap!"                                   # override the recap header
   # - footer_cta: "..."                                                   # optional Slack-mrkdwn footer line

   Tools: Zoom MCP (search_meetings, recordings_list, get_meeting_assets, get_recording_resource), Bash.
   ```

   Store the bot token outside the prompt — e.g. `export RECAP_BOT_TOKEN="xoxb-..."` in `~/.zshenv` (mode 600) so cron/launchd-spawned shells inherit it without the secret appearing in the routine config.

6. **Test it once** by triggering the routine manually after a real meeting — verify the prompts arrive (password / presenter / TLDR as applicable), the replies are captured, and the recap lands in the channel.

## Common failure modes

- **No recording found** → the meeting identifier doesn't match exactly. Check the Zoom topic field for trailing whitespace, "Copy", or differing capitalization.
- **`channel_not_found`** → bot isn't a member of the target recap channel. Invite it with `/invite @<bot-name>`.
- **`not_in_channel`** → same fix.
- **`invalid_auth`** → the bot token is wrong, expired, or revoked. Regenerate in the Slack app config.
- **`missing_scope`** → bot is missing one of the required scopes. The error message lists what's needed. Add it in OAuth & Permissions, reinstall the app, grab the new token.
- **`Could not uniquely resolve handle "<x>"`** → the handle doesn't match a single workspace user. Check the spelling (lowercase, no spaces) and that the user is actually in the workspace.
- **Summary never appears** → Zoom AI Companion may not have been enabled for that meeting. The skill falls back to generating the TLDR from the transcript; if the transcript is also unavailable, it posts recording + password with no TLDR. No further action.
- **Prompt timed out** → no reply to a password/presenter/TLDR question within `prompt_wait_minutes`. The recap is posted with the corresponding line omitted (or no TLDR block). Manually edit the message in Slack, or extend `prompt_wait_minutes` for next time.
- **Recipients see "Sending messages to this app has been turned off"** → Slack app's Messages Tab isn't enabled for user input. Fix in **App Home → Show Tabs**: enable **Messages Tab** AND check **"Allow users to send Slash commands and messages from the messages tab"**. No reinstall required.
