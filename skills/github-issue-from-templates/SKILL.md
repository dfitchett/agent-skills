---
name: github-issue-from-templates
description: Create GitHub issues using data-driven templates. Supports any issue type via configurable template configs. Use when the user asks to create a GitHub ticket, issue, or support ticket, or when they want to add a new issue template.
---

# GitHub Issue Creation — Data-Driven Workflow Engine

This skill creates GitHub issues by dynamically fetching field definitions from GitHub issue templates at runtime. Template metadata (triggers, labels, defaults, formatting rules) is stored in per-template JSON config files. Configs can be stored locally or in a GitHub repository for cross-machine and team sharing. The skill itself contains no hardcoded field definitions.

## File Structure

```
~/.claude/skills/github-issue-from-templates/
  SKILL.md                    # This file — generic workflow engine
  references/
    schema.json               # JSON Schema for template config files
    settings-schema.json      # JSON Schema for settings.json

~/.claude/configs/github-issue-from-templates/
  settings.json               # Storage mode config — created on first run
  .local/                     # Template configs (local mode only) — user-managed, survives skill updates
    *.json
  .cache/                     # Local cache (auto-managed)
    *.json                    # Cached config files (GitHub mode)
    templates/                # Cached issue templates (both modes)
      <config-id>.yml|md

<owner>/<repo>/<path>/        # Template configs (GitHub mode) — canonical source
  *.json
```

> **Why a separate directory?** The skill installation directory (`~/.claude/skills/...`) is replaced on `npx skills update`. Storing template configs in `~/.claude/configs/github-issue-from-templates/.local/` (local mode) or a GitHub repo (GitHub mode) keeps them safe across updates. The `settings.json` file always lives locally since it tells the skill where to find configs.

---

## Tool Detection

Before starting the workflow, verify the `gh` CLI is installed, authenticated, and has the required OAuth scopes.

> **Constraint**: This skill must **never** run any `gh auth` command other than `gh auth status`. All `gh auth` subcommands that modify authentication state (`login`, `logout`, `refresh`, `setup-git`, `token`, `switch`) are **off-limits**. When a scope is missing, display the fix command for the user to run themselves — do not execute it.

### 1. Check installation and authentication

Run `gh auth status`. If the CLI is not installed or not authenticated, notify the user that the [`gh` CLI](https://cli.github.com/) is required and stop.

### 2. Verify OAuth scopes

Parse the `gh auth status` output (note: it writes to **stderr**) and extract the token scopes from the `Token scopes:` line.

```bash
gh auth status 2>&1 | grep -i 'token scopes'
```

Check for the following scopes:

| Scope | Required | Used for |
|-------|----------|----------|
| `repo` | **Always** | Creating issues, reading repository contents (templates, configs) |
| `project` | **For project boards** | Adding issues to project boards, reading project fields (GraphQL API) |

#### Missing scopes — user prompts

Collect all missing scopes before prompting. Then present options based on what's missing:

**If `repo` is missing** (with or without `project`): The workflow cannot continue. Present only one option — tell the user to fix their permissions and let you know when done:

> The `repo` scope is required to create issues and read repository contents. Please run the following command in a separate terminal, then let me know when it's done:
>
> ```bash
> gh auth refresh -s repo,project
> ```
> _(includes `project` for project board support)_

If only `repo` is missing (and `project` is present), adjust the command to `gh auth refresh -s repo`.

After the user confirms they've run the command, re-run `gh auth status` to verify the scopes are now present. If still missing, notify the user and stop.

**If only `project` is missing**: Present two options:

> The `project` scope is needed to assign issues to project boards. You can either:
>
> 1. **Fix now** — Run `gh auth refresh -s project` in a separate terminal, then let me know when it's done.
> 2. **Skip** — Continue without project board support. Created issues will not be added to a project board.

- **If the user chooses option 1**: Wait for confirmation, then re-run `gh auth status` to verify. If still missing, notify the user and offer both options again.
- **If the user chooses option 2**: Set a `projectScopeAvailable = false` flag for this session. Step 2.5 will check this flag and skip project board operations.

### 3. Suggest hook protection

Read the user's global Claude settings (`~/.claude/settings.json`) and check whether it contains a `PreToolUse` hook with `"matcher": "Bash"` whose command references `gh auth` and the blocked subcommands (`login`, `logout`, `refresh`, `setup-git`, `switch`, `token`).

If such a hook is already present, skip this step — no suggestion needed.

If no such hook is found, suggest that the user add one for hard enforcement. Display the following as a recommendation — **do not write to settings.json directly**:

> **Recommended**: You can add a Claude Code hook to your global settings (`~/.claude/settings.json`) that blocks `gh auth` commands other than `gh auth status`. This prevents any skill or agent from modifying your GitHub auth state. To set this up, run `/update-config` and ask to add the hook, or add the following to your `settings.json` manually:
>
> ```json
> "hooks": {
>   "PreToolUse": [
>     {
>       "matcher": "Bash",
>       "hooks": [
>         {
>           "type": "command",
>           "command": "cmd=$(echo \"$CLAUDE_TOOL_INPUT\" | jq -r '.command // \"\"'); if echo \"$cmd\" | grep -qE 'gh auth (login|logout|refresh|setup-git|switch|token)'; then echo 'BLOCKED: Only gh auth status is allowed. Run other gh auth commands manually outside of Claude.' >&2; exit 2; fi"
>         }
>       ]
>     }
>   ]
> }
> ```

Only show this suggestion once per session — if the workflow loops back to Tool Detection (e.g., after a retry), skip this step.

All GitHub operations in this skill use the `gh` CLI exclusively.

---

## Workflow

### Step 0: Settings & Storage Resolution

Before template selection, resolve where configs are stored.

1. Check if `~/.claude/configs/github-issue-from-templates/settings.json` exists.
2. **If it exists**: Read it, validate against `references/settings-schema.json`, and resolve the storage mode:
   - `configStorage.type === "local"` → configs are in `~/.claude/configs/github-issue-from-templates/.local/`
   - `configStorage.type === "github"` → configs are cached locally in `~/.claude/configs/github-issue-from-templates/.cache/` (canonical source is the configured GitHub repo)
3. **If it does not exist**: Run the **Setup Flow** (see below).
4. **Cache management** (GitHub mode only — after resolving `configStorage.type === "github"`):
   - If `~/.claude/configs/github-issue-from-templates/.cache/` **does not exist** → run initial sync (see [Syncing Configs from GitHub](#syncing-configs-from-github)) to download all configs into `.cache/`
   - If `.cache/` **exists** → use cached files directly (no network call)
5. Store the resolved config directory path (`.local/` or `.cache/`) for use in Step 1.

#### Setup Flow (First Run)

Ask the user how they want to store their template configs:

**Option A — Local storage:**
1. Create the directories `~/.claude/configs/github-issue-from-templates/` and `.local/` if they don't exist
2. Write `settings.json`:
   ```json
   {
     "configStorage": {
       "type": "local"
     }
   }
   ```
3. Offer to create a first template config

**Option B — GitHub repository storage:**
1. Ask if they have an existing repo for configs
2. **If yes**:
   - Gather: `owner`, `repo`, `path` (default: `configs/github-issue-from-templates/`), `branch` (default: `main`)
   - Validate access by listing the directory contents (see [Syncing Configs from GitHub](#syncing-configs-from-github) for commands)
   - Write `settings.json`:
     ```json
     {
       "configStorage": {
         "type": "github",
         "owner": "<owner>",
         "repo": "<repo>",
         "path": "configs/github-issue-from-templates/",
         "branch": "main"
       }
     }
     ```
3. **If no** — help create a new repo:
   - Suggest the name `github-issue-from-templates-configs` (default private)
   - `gh repo create <owner>/github-issue-from-templates-configs --private --description "Template configs for github-issue-from-templates skill"`
   - Create the initial directory by committing a placeholder `README.md` at the configured path
   - Write `settings.json` as above
4. After writing `settings.json`, run the initial sync to populate `.cache/` (see [Syncing Configs from GitHub](#syncing-configs-from-github))

#### Switching Storage Modes

If the user asks to change their storage mode (e.g., from local to GitHub or vice versa):

1. Read the current `settings.json` to determine the current mode
2. Ask the user if they want to **migrate** existing configs to the new location:
   - **Local → GitHub**: Read each `.json` config from `.local/`, commit each to the GitHub repo at the configured path via API, then populate `.cache/` from the push responses
   - **GitHub → Local**: Copy each `.json` config from `.cache/` to `.local/`. Remove `.cache/`
3. Update `settings.json` with the new storage configuration
4. Confirm the switch and report how many configs were migrated

---

### Step 1: Template Selection

1. **Load configs** from the resolved config directory (Step 0):
   - **Local**: Read all `.json` files from `~/.claude/configs/github-issue-from-templates/.local/`. If the directory does not exist or contains no config files, offer to create a first template config.
   - **GitHub**: Read all `.json` files from `~/.claude/configs/github-issue-from-templates/.cache/`, **excluding** `README.md`. The cache is populated during Step 0 — no network calls are needed here. If the cache is empty, offer to run a sync or add a first config.
2. For each config, compare the user's request against `triggers.keywords` (case-insensitive substring match) and `triggers.description`.
3. **Single match**: Proceed with that template. Confirm the selection with the user briefly (e.g., "I'll use the [template name] template.").
4. **Multiple matches**: Present the matching templates by `name` and `description` and ask the user to choose.
5. **No match**: Present all available templates by `name` and `description` and ask the user to choose.

---

### Syncing Configs from GitHub

When `configStorage.type === "github"`, use this process to download configs from the remote repo into the local cache at `~/.claude/configs/github-issue-from-templates/.cache/`. This runs during initial setup (Step 0) and on manual sync requests.

#### 1. List files in the config directory

```bash
gh api repos/<owner>/<repo>/contents/<path>?ref=<branch> --jq '.[] | select(.name | endswith(".json")) | select(.name != "settings.json") | .name'
```

#### 2. Fetch each config file

```bash
gh api repos/<owner>/<repo>/contents/<path>/<filename>?ref=<branch> --jq '.content' | base64 -d
```

#### 3. Save to local cache

Write each fetched file to `~/.claude/configs/github-issue-from-templates/.cache/<filename>`. Create the `.cache/` directory if it doesn't exist.

Parse each fetched file as JSON. Skip files that fail to parse and notify the user (see [Error Handling](#error-handling)).

#### 4. Sync templates (optional)

For each config that was just synced, optionally fetch the corresponding issue template and save it to `.cache/templates/<config.id>.<config.templateSource.format>`. Create the `.cache/templates/` directory if it doesn't exist. This step is optional — templates will be fetched lazily on first use in Step 2 if skipped here.

---

### Step 2: Fetch Template from GitHub

Before fetching from GitHub, check the local template cache:

1. **Check cache**: Look for `~/.claude/configs/github-issue-from-templates/.cache/templates/<config.id>.<config.templateSource.format>`
2. **If cached** → read the file contents from cache and skip the GitHub API call
3. **If not cached** → fetch from GitHub using the `gh` CLI, then save the raw content to `.cache/templates/<config.id>.<config.templateSource.format>`. Create the `.cache/templates/` directory if it doesn't exist.

```bash
gh api repos/<config.repository.owner>/<config.repository.repo>/contents/<config.templateSource.path> --jq '.content' | base64 -d
```

Then parse based on `config.templateSource.format`:

#### Format: `yml` (Form-based templates)

Parse the YAML content and extract:
- **Title pattern**: From the top-level `title:` field (e.g., `"[Issue Type] [Short descriptive title]"`)
- **Template-level labels**: From the top-level `labels:` array
- **Template-level assignees**: From the top-level `assignees:` array
- **Fields**: From the `body:` array. For each entry:
  - Skip entries where `type: markdown` — these are instructional text, not fields
  - For all other entries, extract:
    - `id` — unique field identifier
    - `type` — `dropdown`, `input`, `textarea`
    - `attributes.label` — human-readable field name
    - `attributes.description` — help text for the field
    - `attributes.options` — available choices (for dropdowns)
    - `attributes.placeholder` — example/guidance text
    - `validations.required` — whether the field must be filled

#### Format: `md` (Frontmatter + markdown templates)

Parse the frontmatter (between `---` delimiters) and extract:
- **Title pattern**: From `title:` (e.g., `'[A11y]: Product - Feature - Request'`)
- **Template-level labels**: From `labels:` (may be a string or array)
- **Template-level assignees**: From `assignees:` (may be a string or array)

Parse the markdown body to identify:
- **Sections**: `##` headings define major sections
- **Checkbox groups**: Lines matching `- [ ] Item text` grouped under a heading or bold label
- **Labeled fields**: Bold-labeled list items like `- **Team name:**` under a section
- **Self-verification checklists**: Sections like "Yes, I have" contain items the skill should satisfy automatically

### Step 2.5: Project Board Check

**Scope gate**: If the user chose to skip the `project` scope in Step 2 (`projectScopeAvailable = false`), skip this entire step. Set `config.projectBoard` to `null` for this session and continue to Step 3.

After selecting a template config, check whether `config.projectBoard` is defined:

1. **If `config.projectBoard` exists** with at least `name`, `number`, and `nodeId`: Proceed — the project and its field defaults will be shown in the preview (Step 5).
2. **If `config.projectBoard` is missing or incomplete**: Prompt the user:
   - "This template doesn't have a default project board configured. Would you like to assign one?"
   - **If yes**: Run the **Project Gathering** flow (below) and persist the result back to the config file (same save logic as [Updating an Existing Template Config](#updating-an-existing-template-config)).
   - **If no**: Continue without a project. Set `config.projectBoard` to `null` for this session so the preview omits the project line.

#### Project Gathering

##### Step A: Identify the project

Ask the user for:

1. **Project URL or number** — if the user provides a URL (e.g., `https://github.com/orgs/ORG/projects/123`), extract the owner, owner type (`organization` or `user`), and number automatically. Otherwise ask for the number.
2. **Project owner** — defaults to `config.repository.owner` if not provided or extracted from URL.
3. **Owner type** — if not obvious from the URL, ask whether the owner is an organization or a user. Default to `organization`.

##### Step B: Fetch project details and fields via GraphQL

Use the GitHub GraphQL API via `gh api graphql` to fetch the project's node ID, name, and fields in a single query:

```bash
gh api graphql -f query='
  query($owner: String!, $number: Int!) {
    <ownerType>(login: $owner) {
      projectV2(number: $number) {
        id
        title
        fields(first: 50) {
          nodes {
            ... on ProjectV2Field {
              id
              name
              dataType
            }
            ... on ProjectV2IterationField {
              id
              name
              dataType
              configuration {
                iterations {
                  id
                  title
                  startDate
                }
              }
            }
            ... on ProjectV2SingleSelectField {
              id
              name
              dataType
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }
' -f owner='<owner>' -F number=<number>
```

Replace `<ownerType>` with `organization` or `user` based on the owner type determined in Step A.

From the response, extract:
- **`id`** → store as `projectBoard.nodeId`
- **`title`** → store as `projectBoard.name` (confirm with the user: "I found project **[title]** — is this correct?")
- **`fields.nodes`** → the list of project fields with their types and options

##### Step C: Prompt for field defaults

Present the fetched fields to the user and ask which ones should have default values. For each field:

1. **Skip built-in fields** that are auto-managed by GitHub: `Title`, `Assignees`, `Labels`, `Linked pull requests`, `Reviewers`, `Repository`, `Milestone`. These are set via the issue itself, not project field values.
2. **Single-select fields** (e.g., Status, Priority): Present the available options as a numbered list and ask the user to pick a default, or skip.
3. **Iteration fields** (e.g., Sprint): Present the available iterations and ask the user to pick a default, or skip. Note that iteration defaults may go stale as sprints progress — mention this to the user.
4. **Text, number, and date fields**: Ask for a default value or skip.

For each field where the user provides a default, store it in `projectBoard.fieldDefaults` keyed by the field's node ID:

```json
{
  "<field-node-id>": {
    "fieldName": "Status",
    "value": {
      "display": "Backlog",
      "optionId": "<option-node-id>"
    }
  }
}
```

- For single-select fields: include both `display` and `optionId`
- For iteration fields: include both `display` and `iterationId`
- For text/number/date fields: include only `display` (the literal value)

**Gathering style**: Don't present every field one at a time. Instead, list all eligible fields with their types and current options in a single message, and ask the user which ones they'd like to set defaults for. Then gather the values for just those fields.

##### Step D: Assemble the `projectBoard` object

Return a complete `projectBoard` object matching the schema in `references/schema.json`:

```json
{
  "name": "BMT Team 2 Board",
  "number": 123,
  "nodeId": "PVT_kwHOABC123",
  "url": "https://github.com/orgs/ORG/projects/123",
  "owner": "ORG",
  "ownerType": "organization",
  "fieldDefaults": {
    "PVTSSF_field1": {
      "fieldName": "Status",
      "value": { "display": "Backlog", "optionId": "opt_abc123" }
    },
    "PVTSSF_field2": {
      "fieldName": "Priority",
      "value": { "display": "High", "optionId": "opt_def456" }
    }
  }
}
```

---

### Step 3: Gather Information

For each extracted field, apply the following logic in order:

1. **Pre-fill from user request**: If the user already provided a value for this field in their initial message, pre-fill it and confirm during the preview step.

2. **Apply defaults**: Check `config.fieldDefaults[fieldId].value` — if present, use as the default. Also check `config.defaults` for matching keys.

3. **Check skip conditions**: Check `config.fieldSkipConditions[fieldId]` — if an `onlyWhen` condition exists and is not met, skip this field entirely.

4. **Prompt if needed**: If the field is required (`validations.required: true`) and no value has been determined, prompt the user. Use the field's `label` as the question and `description`/`placeholder` as guidance.

5. **Apply gathering notes**: Use `config.fieldDefaults[fieldId].gatheringNotes` for additional guidance on how to present or gather this field.

**Gathering style**:
- Be conversational — don't present a wall of questions
- Batch related questions together (e.g., ask for summary and description in one turn)
- For dropdowns, present the options from the template
- For fields with defaults, mention the default and ask if it's correct
- Skip optional fields that the user hasn't mentioned unless they're likely relevant

### Step 4: Compose Issue

#### Title

Build the title by substituting placeholders in the title pattern:
- Use `config.title.override` if present; otherwise use the pattern extracted from the template in Step 2
- Replace placeholder text with gathered field values using reasoning (e.g., `[Issue Type]` → the value of the `issue-type` field, `[Short descriptive title]` → the `summary` field value)

#### Body

Render the issue body following the structure from the fetched template:
- **yml templates**: Render each field as a `### Field Label` section with the gathered value. Use `no response` for empty optional sections. Maintain the exact field order from the template.
- **md templates**: Reconstruct the markdown body with gathered values filled in. Check the appropriate checkboxes, fill in labeled fields, and include all sections.

#### Labels

Build the label set:
1. Start with `config.labels.default`
2. Merge in template-level labels (from the fetched template's `labels:` field) — avoid duplicates
3. Apply `config.labels.conditional` rules:
   - **`keyword`**: Check if any keyword appears in the user's request (case-insensitive)
   - **`fieldValue`**: Check if the specified field has the specified value
   - **`fieldTransform`**: Derive a label from a field value using the specified transform (e.g., `lowercase-hyphenate` converts "Document Status" to "document-status")
4. Apply any additional label logic defined in the template config's `notes`

#### Assignees

Merge `config.assignees.default` with template-level assignees. If `config.assignees.promptUser` is true, ask the user if they want to assign anyone else.

### Step 5: Preview & Confirm

Present the composed issue to the user for review:

```
**Title**: [composed title]
**Labels**: label1, label2, label3
**Assignees**: @user1, @user2
**Project**: [project board name] (Status: Backlog, Priority: High, ...)   ← only if config.projectBoard is set

**Body**:
[rendered body preview]
```

- If `config.projectBoard` is set, display the project name. If `config.projectBoard.fieldDefaults` contains entries, list the default field values that will be applied (e.g., "Status: Backlog, Priority: High").
- If `config.projectBoard` is `null` or missing, omit the **Project** line entirely.

Ask for confirmation or edits. If the user requests changes, apply them and re-preview.

### Step 6: Create Issue

Create the issue using `gh issue create`:

```bash
gh issue create \
  --repo <config.repository.owner>/<config.repository.repo> \
  --title "<composed title>" \
  --body "<composed body>" \
  --label "<label1>" --label "<label2>" \
  --assignee "<assignee1>" --assignee "<assignee2>"
```
- Pass each label and assignee as a separate `--label` / `--assignee` flag
- Use a heredoc for the body if it contains special characters:
  ```bash
  gh issue create \
    --repo owner/repo \
    --title "Title" \
    --body "$(cat <<'EOF'
  <composed body>
  EOF
  )" \
    --label "label1" --label "label2"
  ```
- Parse the issue URL from the command output (printed to stdout on success)

### Step 7: Post-Creation

The `gh issue create` command prints the issue URL to stdout. **Always display the issue URL to the user** as a clickable link, regardless of whether `config.postCreation` is configured. This is the minimum required output on success.

If `config.postCreation.displayFormat` is defined, also render it by substituting `{issueNumber}` and `{issueUrl}` with actual values.

Display each item from `config.postCreation.additionalNotes` as a follow-up note.

---

## Link Formatting Rules

When rendering links in the issue body, apply the rules from `config.linkFormatting.rules` in order. For each link:

1. Check each rule's `match` description to determine if it applies
2. Apply the `format` specified by the matching rule
3. Use `customText` as link text if provided

**Common patterns**:
- GitHub issue/PR URLs as list items → raw URL (no markdown wrapping) so GitHub renders title + status
- Design links → markdown link with `(see design)` as text
- All other links → standard markdown `[descriptive text](url)`

---

## Acceptance Criteria

When `config.acceptanceCriteria` is defined:

1. Start with `config.acceptanceCriteria.defaultItems` as baseline criteria
2. Ask the user for additional criteria
3. Render using `config.acceptanceCriteria.formatting.style` (`checklist` = `- [ ] item`, `bullets` = `- item`)
4. Avoid the prefixes listed in `config.acceptanceCriteria.formatting.avoidPrefixes`

---

## Error Handling

### Malformed settings.json
If `settings.json` exists but fails validation against `references/settings-schema.json`:
- Notify the user that the settings file is invalid
- Show the specific validation error
- Offer to re-run the Setup Flow to create a new `settings.json`

### GitHub sync failure
If syncing configs from GitHub fails (during initial setup or manual sync):
- **If `.cache/` exists with files**: Warn the user that the sync failed, but continue using the existing cached configs. Suggest retrying later.
- **If `.cache/` is empty or does not exist**: Cannot proceed with GitHub mode. Notify the user and offer to switch to local storage mode.
- Suggest checking: repository existence, access permissions, branch name
- Suggest `gh auth status` to verify authentication

### Empty config directory
If the config directory (`.local/` or `.cache/`) exists but contains no `.json` config files:
- Notify the user that no template configs were found
- Offer to create a first template config
- For GitHub mode, suggest running a sync if the remote repo may have configs

### Config write failure (GitHub)
If pushing a config to GitHub fails:
- The config is still saved locally in `.cache/` — confirm this to the user
- Provide context about potential causes: branch protection rules, insufficient permissions, file conflicts
- If the error includes a SHA mismatch, suggest re-fetching the file and retrying
- Suggest the user sync later once the issue is resolved

### Cached template parse failure
If a cached template file in `.cache/templates/` fails to parse:
- Delete the cached template file
- Re-fetch from GitHub using the normal Step 2 flow
- If the re-fetch also fails, fall back to the template fetch failure handling below

### Template fetch failure
If the template fetch fails (`gh api`) and no valid cache exists:
- Notify the user that the template could not be fetched
- Suggest checking repository access permissions
- Suggest running `gh auth status` to verify authentication
- Offer to create the issue manually without template structure

### JSON config parse failure
If a template config file is malformed:
- Skip that template during selection
- Notify the user which config failed to parse

### Issue creation failure
If `gh issue create` fails:
1. Stop the operation immediately
2. Notify the user of the failure
3. Provide context about potential causes: authentication token issues, permissions, rate limits, invalid repository access
4. Include the stderr output from the `gh` command for diagnostics
5. Offer to display the composed issue body so the user can create it manually

---

## Adding a New Template

To add support for a new issue type, create a new `.json` config file following the schema in `references/schema.json`. The save location depends on the storage mode configured in `settings.json`:

### Local storage (`configStorage.type === "local"`)

1. Create a new `.json` file in `~/.claude/configs/github-issue-from-templates/.local/`
2. Follow the schema defined in `references/schema.json`
3. Set `repository.owner` and `repository.repo` to the target GitHub repository
4. Set `templateSource.path` to the repo-relative path of the GitHub issue template
5. Set `templateSource.format` to `yml` or `md` based on the template type
6. Define `triggers.keywords` for automatic template matching
7. **Prompt for a default project board**: Run the [Project Gathering](#project-gathering) flow to populate `projectBoard`. If the user declines, omit the `projectBoard` property.
8. Add any `fieldDefaults`, `fieldSkipConditions`, label rules, and formatting overrides
9. No changes to this SKILL.md file are needed

### GitHub storage (`configStorage.type === "github"`)

1. Compose the config JSON following `references/schema.json`
2. **Prompt for a default project board**: Run the [Project Gathering](#project-gathering) flow to populate `projectBoard`. If the user declines, omit the `projectBoard` property.
3. Write the file to the local cache at `~/.claude/configs/github-issue-from-templates/.cache/<filename>.json` (immediately available for use)
4. Push to GitHub:
   ```bash
   gh api repos/<owner>/<repo>/contents/<path>/<filename>.json \
     --method PUT \
     --field message="Add <template-name> template config" \
     --field branch=<branch> \
     --field content=$(echo '<JSON content>' | base64)
   ```

5. If the push fails, the config is still saved locally in `.cache/` — warn the user to sync later once the issue is resolved
6. No changes to this SKILL.md file are needed

---

## Updating an Existing Template Config

### Local storage

Read, edit, and overwrite the `.json` file in `~/.claude/configs/github-issue-from-templates/.local/` directly.

### GitHub storage

1. **Edit the file** in the local cache at `~/.claude/configs/github-issue-from-templates/.cache/<filename>.json`
2. **Fetch the current SHA** from GitHub:
   ```bash
   gh api repos/<owner>/<repo>/contents/<path>/<filename>.json?ref=<branch> --jq '.sha'
   ```

3. **Push the updated file** to GitHub with the SHA:
   ```bash
   gh api repos/<owner>/<repo>/contents/<path>/<filename>.json \
     --method PUT \
     --field message="Update <template-name> template config" \
     --field branch=<branch> \
     --field content=$(echo '<updated JSON>' | base64) \
     --field sha=<current SHA>
   ```

4. If the push fails, the local cache already has the update — warn the user to sync later once the issue is resolved

---

## Syncing Configs

### Manual sync

If the user asks to sync configs (or if configs seem stale), re-run the full download flow from [Syncing Configs from GitHub](#syncing-configs-from-github). This overwrites the contents of `.cache/` with the latest files from the remote repo. Additionally, for each synced config, re-fetch the issue template from GitHub and update `.cache/templates/<config.id>.<config.templateSource.format>`.

> **Note:** Templates are cached lazily (on first use in Step 2), so a manual sync only refreshes templates for configs that already have a cached template in `.cache/templates/`.

### Force refresh

Delete the `.cache/` directory entirely. The next skill invocation will detect the missing cache and re-download everything during Step 0. This removes both cached configs and cached templates. To only refresh templates, delete `.cache/templates/` — templates will be re-fetched lazily on next use.

### When to suggest a sync

- The user mentions that configs seem stale or different from what's in GitHub
- A push succeeded on one machine but another machine doesn't reflect the change
- After resolving a GitHub access issue that previously blocked syncing

---

## Section Formatting Conventions

- Use `no response` for any section where no information was provided — never omit sections
- Include all template sections in the exact order they appear in the fetched template
- Use bullet points for lists
- Use proper markdown formatting
- Label names: lowercase with hyphens (e.g., `document-status`, `bmt-team-2`)
