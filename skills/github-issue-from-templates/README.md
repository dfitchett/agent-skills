# github-issue-from-templates

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that creates GitHub issues by fetching field definitions from GitHub issue templates at runtime. You define lightweight JSON configs that point to your repo's issue templates — the skill handles template parsing, conversational information gathering, issue composition, and creation via the GitHub MCP or `gh` CLI.

## How It Works

1. **First run**: The skill asks where you want to store template configs — locally or in a GitHub repo
2. You say something like "create a bug ticket"
3. The skill matches your request to a template config via keywords
4. It fetches the actual GitHub issue template from your repo
5. It walks you through the fields conversationally, applying any defaults you've configured
6. It previews the composed issue and creates it on confirmation

The skill engine (`SKILL.md`) is completely generic. All project-specific behavior — repos, labels, defaults, assignees — lives in the template config JSON files. Storage settings are persisted in `settings.json` so the skill remembers your choice across sessions.

## Installation

```bash
npx skills add dfitchett/skills/github-issue-from-templates
```

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
- **One of the following** for GitHub access:
  - [GitHub MCP server](https://github.com/github/github-mcp-server) configured (preferred), **or**
  - [`gh` CLI](https://cli.github.com/) installed and authenticated (`gh auth login`)
- Access to the repositories containing your issue templates

## File Structure

```
~/.claude/skills/github-issue-from-templates/   # Skill installation (managed by npx skills)
  SKILL.md                                        # Workflow engine
  references/
    schema.json                                   # JSON Schema for template config validation
    settings-schema.json                          # JSON Schema for settings.json validation

~/.claude/configs/github-issue-from-templates/   # Local settings + configs
  settings.json                                   # Storage mode configuration (created on first run)
  .local/                                         # Template configs (local mode only)
    *.json
  .cache/                                         # Local cache of GitHub configs (GitHub mode, auto-managed)
    *.json
```

The `settings.json` file always lives locally at `~/.claude/configs/github-issue-from-templates/settings.json`. Template configs are stored in `.local/` (local mode) or cached in `.cache/` from a GitHub repository (GitHub mode), depending on your chosen storage mode.

## Config Storage

On first run, the skill asks where to store template configs. You can choose between two modes:

### Local Storage

Configs are stored as `.json` files in `~/.claude/configs/github-issue-from-templates/.local/`. This is the simplest option — configs live on your machine alongside the skill settings.

- No additional setup required
- Configs are only available on the current machine
- Configs survive skill updates (stored outside the skill installation directory)

### GitHub Repository Storage

Configs are stored in a GitHub repository. This enables sharing configs across machines and with team members, with version control built in.

- Configs are cached locally after first sync — reads are instant, no network calls on each run
- Manual sync available to pull the latest from GitHub at any time
- Changes are saved to the local cache first, then committed back to the repo
- Share the same configs across multiple machines
- Team members can use the same config repo
- The skill can help create a new private repo (`github-issue-from-templates-configs`) or use an existing one

### Switching Modes

You can switch storage modes at any time by asking the skill. It will offer to migrate existing configs to the new location.

## Adding a Template

Create a JSON file following the schema in `references/schema.json` that points to an existing GitHub issue template in your repo. Here's a minimal example:

```json
{
  "id": "bug-report",
  "name": "Bug Report",
  "description": "Report a bug in the project.",
  "version": "1.0.0",
  "triggers": {
    "keywords": ["bug", "defect", "broken", "regression"],
    "description": "Use when reporting a bug or defect."
  },
  "repository": {
    "owner": "my-org",
    "repo": "my-repo"
  },
  "templateSource": {
    "path": ".github/ISSUE_TEMPLATE/bug-report.yml",
    "format": "yml"
  },
  "labels": {
    "default": ["bug"]
  }
}
```

**Where to save it** depends on your storage mode:

- **Local**: Save the file directly to `~/.claude/configs/github-issue-from-templates/.local/<name>.json`
- **GitHub**: The skill commits the file to your config repo — just ask it to add a new template and it will walk you through the process

The skill fetches the actual template from GitHub at runtime, so you don't duplicate field definitions. Your config only adds:

- **Trigger keywords** for matching user requests
- **Defaults** for fields you want pre-filled
- **Field skip conditions** for conditional fields
- **Label rules** (static defaults + conditional based on keywords or field values)
- **Assignee defaults**
- **Gathering notes** to guide the conversational flow

### Supported Template Formats

| Format | File Extension | Description |
|--------|---------------|-------------|
| `yml` | `.yml` | GitHub form-based templates with typed fields (dropdowns, inputs, textareas) |
| `md` | `.md` | Frontmatter + markdown body with sections, checkboxes, and labeled fields |

## Settings Reference

The `settings.json` file controls where template configs are stored. See `references/settings-schema.json` for the full schema.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `configStorage.type` | `"local"` or `"github"` | Yes | Where configs are stored |
| `configStorage.owner` | string | GitHub only | GitHub owner (user or org) of the config repo |
| `configStorage.repo` | string | GitHub only | Repository name |
| `configStorage.path` | string | No | Directory path within the repo (default: `configs/github-issue-from-templates/`) |
| `configStorage.branch` | string | No | Branch name (default: `main`) |

## Template Config Reference

See [`references/schema.json`](references/schema.json) for the complete schema. Key sections:

| Section | Purpose |
|---------|---------|
| `triggers` | Keywords and description for matching user requests |
| `repository` | Target GitHub org/repo for issue creation |
| `templateSource` | Path and format of the GitHub issue template to fetch |
| `defaults` | Key-value constants (e.g., team name) |
| `fieldDefaults` | Per-field default values and gathering guidance |
| `fieldSkipConditions` | Conditional field visibility based on other field values |
| `labels` | Default labels + conditional rules (keyword, fieldValue, fieldTransform) |
| `assignees` | Default assignees + whether to prompt for more |
| `acceptanceCriteria` | Baseline items and formatting preferences |
| `linkFormatting` | Rules for rendering different link types in the issue body |
| `postCreation` | Success message template and follow-up notes |

## Usage

Once installed with at least one template config, invoke the skill in Claude Code:

```
/github-issue-from-templates
```

Or just describe what you need — the skill matches keywords automatically:

> "Create a bug ticket for the login page being broken on mobile"

## License

MIT
