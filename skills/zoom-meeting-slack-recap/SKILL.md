---
name: zoom-meeting-slack-recap
description: Post a Zoom meeting recap (TLDR, summary link, recording link, password) to a Slack channel via a Slack bot. Designed to be invoked from a cron-scheduled routine that fires ~30 min after a recurring meeting ends. Pulls the most recent recording via the Zoom MCP, optionally DMs a group of people to ask for the recording password, polls for their reply, then posts the recap. If Zoom's AI summary is still processing, posts a recording-only message first and edits it in place once the summary lands. Use when the user says "post the meeting recap to Slack", "publish the Zoom summary", "/zoom-meeting-slack-recap", or wires up a new recurring-meeting routine.
---

# Zoom Meeting Slack Recap

Post a Slack message recapping a recent Zoom meeting: TLDR, full-summary link, recording link, and (optionally) password.

This skill expects to run inside a **cron-scheduled routine**. One routine per recurring meeting, scheduled ~30 minutes after the meeting ends. The routine's prompt carries the meeting-specific inputs.

The recording password is **not** baked into the routine. Instead, the skill DMs a group of people you specify and asks them to reply with the password — the first reply wins. This avoids storing the password in the routine config and lets passwords rotate per session.

## Required inputs

The invoking routine prompt must supply:

| Field | Description |
|---|---|
| `meeting_id_or_title` | Either an exact Zoom meeting topic (e.g. `"BMT Team 2 Standup"`) or a numeric Zoom meeting ID. Used to locate the most recent recording. |
| `slack_channel` | Channel name (e.g. `#bmt-team-2`) or channel ID (e.g. `C0123ABCDEF`) — where the recap is posted. The bot must already be a member. |
| `slack_bot_token` | A Slack bot token (`xoxb-...`). See **Required bot scopes** below. |
| `password_prompt_handles` | List of Slack handles (e.g. `["@derek-fitchett", "@yinka"]`) — the people who will be DM'd to ask for the password. Handles must match the Slack workspace's `name` field for each user (the lowercase `@handle`, not the display name). |
| `password_wait_minutes` *(optional)* | How long to wait for a password reply before falling back to a recording-only post. Defaults to `15`. |
| `custom_note` *(optional)* | One-liner prepended above the message body in the recap (e.g. `"Recap for folks who missed today's sync"`). |

If any required field is missing, stop and report which — do not guess.

## Required bot scopes

The Slack app powering this skill needs these OAuth bot scopes:

- `chat:write` — post the recap
- `chat:write.public` — post to public channels the bot isn't a member of *(optional but convenient)*
- `users:read` — resolve `@handle` strings to user IDs
- `mpim:write` — open a multi-person DM with the password-prompt recipients
- `mpim:history` — poll the DM for password replies
- `im:write`, `im:history` — same, for the 1-recipient case (Slack uses a 1:1 DM instead of an mpim)

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

If the matched recording's `start_time` is **more than 4 hours ago**, exit silently — do not DM anyone and do not post. This prevents stale chatter when a meeting was canceled or rescheduled and the cron routine still fired.

Log a one-line note locally (e.g. "Skipping: most recent recording is N hours old") but don't error and don't message Slack.

### 3. Ask the group for the recording password

Now that a fresh recording is confirmed, run the bundled helper script `ask-slack-password.sh` (sits alongside this SKILL.md). It handles auth, paginated handle-to-user-ID resolution, DM open, prompt post, reply polling, HTML-entity decoding, and the timeout follow-up — so the routine LLM does not need to chain ~8 curl calls itself.

```bash
"$(dirname "$0")/ask-slack-password.sh" \
  --token "${slack_bot_token}" \
  --handles "${password_prompt_handles_csv}" \
  --meeting-title "${meeting_topic}" \
  --meeting-date "${human_readable_date}" \
  --recap-channel "${slack_channel}" \
  --wait-minutes "${password_wait_minutes:-15}"
```

`${password_prompt_handles_csv}` is the input list joined with commas, with or without `@` (e.g. `"derek.fitchett,yinka"`). The script also accepts a `--poll-interval` flag (default 30 seconds) if you need to tune polling.

**Script exit behavior:**
- **Exit 0** → stdout contains the captured password (already HTML-decoded). Use it verbatim as `zoom_password`.
- **Exit 1** → no reply in the wait window. The script has already posted a follow-up to the DM. Set `zoom_password = null` and continue.
- **Exit 2** → config/auth error (bad token, missing scope, unresolvable handle, etc.). Stderr explains; abort the routine.

Capture stdout into a variable:

```bash
zoom_password=$("$(dirname "$0")/ask-slack-password.sh" ...args... ) || zoom_password=""
```

If the variable is empty after this step, the recap will be posted without the 🔑 line.

### 4. Try to fetch the AI summary

Use **`get_meeting_assets`** with the meeting UUID to retrieve the AI Companion summary. Look for the **Quick recap** section (Zoom's short overview) inside `meeting_summary.summary_markdown` or `summary_plain_text`.

The summary may not be ready yet. Treat it as "ready" only if `meeting_summary.has_summary` is true AND the Quick recap section is non-empty.

### 5. Post the recap to the configured Slack channel

Use Slack's Web API via `curl`:

```bash
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${slack_bot_token}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data @- <<'JSON'
{
  "channel": "<slack_channel>",
  "text": "<message text>",
  "unfurl_links": false,
  "unfurl_media": false
}
JSON
```

Capture the `ts` from the response — needed if you later edit the message.

#### Message format

The recap has these lines, in order:

```
*<Meeting Title> Recap!*
[custom_note line, if provided]
*Meeting:* <human-readable date>, <duration> min

*TLDR:* <Zoom Quick recap, verbatim>     ← omit this block if summary not ready

📄 <summary-doc-url|*Full summary*>      ← omit if summary not ready
🎥 <recording-share-url|*Recording*>
🔑 *Password:* `<zoom_password>`         ← omit if password is null
```

Slack link syntax: `<url|display text>` makes the display text clickable while hiding the raw URL. Wrap the password in backticks so characters like `*` or `&` don't trigger Slack formatting.

Render the date in the user's local timezone (America/New_York by default) — e.g. `Tue May 14, 11:00 AM ET`.

When summary is **not** ready, append a footer line:

```
_Summary still processing — will update this message when ready._
```

#### 5a. Both summary and password ready → done

Post the full message. Move to step 6.

#### 5b. Summary not ready → post the partial, then poll-and-edit

Post the partial message (omitting the TLDR + Full summary lines, adding the "summary still processing" footer). Save the `ts`.

Poll every **3 minutes**, retry `get_meeting_assets` for the summary. Cap at **5 attempts (≈15 minutes total)**.

As soon as the Quick recap appears, call `chat.update` with the same channel + ts:

```bash
curl -s -X POST https://slack.com/api/chat.update \
  -H "Authorization: Bearer ${slack_bot_token}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data @- <<'JSON'
{
  "channel": "<slack_channel>",
  "ts": "<original ts>",
  "text": "<full message with TLDR and summary link>"
}
JSON
```

The edited body is the full message format above — without the "summary still processing" footer. If 15 minutes elapse without the summary appearing, leave the recording-only message in place.

### 6. Report what happened

End the routine with a one-line status:

- `Posted full recap to <channel> (ts=<ts>); password from <handle> in <N>s` — happy path
- `Posted recording-only to <channel>, edited with summary after <N>m (ts=<ts>); password from <handle>` — summary-poll edit succeeded
- `Posted recording-only to <channel>, summary never arrived (ts=<ts>); password from <handle>` — summary poll gave up
- `Posted recap to <channel> without password (ts=<ts>); group DM timed out after <N>m` — password-poll gave up
- `Skipped: most recent recording is <N>h old (>4h threshold)` — stale guard fired (no DMs sent)
- `Failed: <reason>` — anything else

## Setting up a new recurring routine

To wire up the first routine that uses this skill:

1. **Create a Slack app** (one-time) at https://api.slack.com/apps:
   - "From scratch" → name it → pick your workspace
   - Under **OAuth & Permissions**, add **all bot scopes** listed in the "Required bot scopes" section above
   - Under **App Home → Show Tabs**, enable **Messages Tab** AND check **"Allow users to send Slash commands and messages from the messages tab"**. Without this, recipients see "Sending messages to this app has been turned off" when they try to reply to the password prompt, and polling will time out.
   - Install to workspace → copy the `xoxb-…` token
   - `/invite @<bot-name>` in every channel the bot needs to post in
   - For each password-prompt recipient, no special setup is needed beyond the bot being installed in the workspace

2. **Identify the meeting**: confirm the exact Zoom topic string or numeric ID by checking one prior recording via the Zoom MCP. Mismatches here cause the skill to silently skip.

3. **Find each recipient's Slack handle**: in Slack, click a person's profile → look for `@<handle>` under their display name. This is the value that goes in `password_prompt_handles`.

4. **Pick the cron expression**: schedule for ~30 minutes after the meeting's typical end time. Example for an 11:00 AM ET Tuesday meeting that runs until ~11:30:

   - `30 16 * * 2` *(11:30 AM ET → 16:30 UTC during EDT)*
   - Confirm timezone handling with your routine runner — some use UTC, some use local

5. **Create the routine** using `/schedule` (or `mcp__scheduled-tasks__create_scheduled_task`). The routine prompt should look like:

   ```
   Use the zoom-meeting-slack-recap skill with these inputs:
   - meeting_id_or_title: "Engineering CoP"
   - slack_channel: "#staff-test"
   - slack_bot_token: "xoxb-..."
   - password_prompt_handles: ["@derek-fitchett", "@yinka"]
   - password_wait_minutes: 15
   - custom_note: "Recap from today's CoP"
   ```

6. **Test it once** by triggering the routine manually after a real meeting — verify the DM arrives, the password is captured, and the recap lands in the channel.

## Common failure modes

- **No recording found** → the meeting identifier doesn't match exactly. Check the Zoom topic field for trailing whitespace, "Copy", or differing capitalization.
- **`channel_not_found`** → bot isn't a member of the target recap channel. Invite it with `/invite @<bot-name>`.
- **`not_in_channel`** → same fix.
- **`invalid_auth`** → the bot token is wrong, expired, or revoked. Regenerate in the Slack app config.
- **`missing_scope`** → bot is missing one of the required scopes. The error message lists what's needed. Add it in OAuth & Permissions, reinstall the app, grab the new token.
- **`Could not uniquely resolve handle "<x>"`** → the handle doesn't match a single workspace user. Check the spelling (lowercase, no spaces) and that the user is actually in the workspace.
- **Summary never appears** → Zoom AI Companion may not have been enabled for that meeting, or the host hasn't shared the recording yet. The recording-only post is the correct fallback; no further action.
- **Group DM timed out** → no recipient replied within `password_wait_minutes`. Recap is posted without a password. Manually edit the message in Slack or extend `password_wait_minutes` for next time.
- **Recipients see "Sending messages to this app has been turned off"** → Slack app's Messages Tab isn't enabled for user input. Fix in **App Home → Show Tabs**: enable **Messages Tab** AND check **"Allow users to send Slash commands and messages from the messages tab"**. No reinstall required.
