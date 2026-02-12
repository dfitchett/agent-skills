# github-issue-from-templates

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill that creates GitHub issues by fetching field definitions from GitHub issue templates at runtime. You define lightweight JSON configs that point to your repo's issue templates — the skill handles template parsing, conversational information gathering, issue composition, and creation via the GitHub MCP.

## How It Works

1. You say something like "create a bug ticket"
2. The skill matches your request to a template config via keywords
3. It fetches the actual GitHub issue template from your repo
4. It walks you through the fields conversationally, applying any defaults you've configured
5. It previews the composed issue and creates it on confirmation

The skill engine (`SKILL.md`) is completely generic. All project-specific behavior — repos, labels, defaults, assignees — lives in the template config JSON files.

## Installation

```bash
npx skills add dfitchett/skills/github-issue-from-templates
```

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with the [GitHub MCP server](https://github.com/github/github-mcp-server) configured
- GitHub access to the repositories containing your issue templates

## File Structure

```
github-issue-from-templates/
  SKILL.md                    # Workflow engine (do not edit for project-specific changes)
  references/
    schema.json               # JSON Schema for template config validation
  assets/
    *.json                    # Your template configs (one per issue type)
```

## Adding a Template

Create a JSON file in `assets/` that points to an existing GitHub issue template in your repo. Here's a minimal example:

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
