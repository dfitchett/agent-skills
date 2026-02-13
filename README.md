# Agent Skills

A collection of skills for AI coding agents. Skills are packaged instructions and references that extend agent capabilities. Built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) and compatible with the [Agent Skills](https://agentskills.io/) format.

## Available Skills

### [github-issue-from-templates](./github-issue-from-templates)

Create GitHub issues by fetching field definitions from your repo's issue templates at runtime. Define lightweight JSON configs — the skill handles template parsing, conversational information gathering, issue composition, and creation.

- Supports both YAML form-based (`.yml`) and frontmatter + markdown (`.md`) GitHub issue templates
- Configurable defaults, conditional labels, assignee rules, and field skip conditions
- Conversational gathering — batches related questions, applies defaults, skips irrelevant fields
- Preview and confirm before creation

**Use cases:** "Create a bug ticket", "File an accessibility review", "Make a new issue for the login feature"

## Installation

Install all skills:

```bash
npx skills add dfitchett/agent-skills
```

Install a single skill:

```bash
npx skills add dfitchett/agent-skills --skill github-issue-from-templates
```

_note: sometimes Claude code has issues finding the skill due to the locations skills are installed from the tool call above. To install specifically for Claude Code, install via:

```bash
npx skills add dfitchett/agent-skills --skill github-issue-from-templates -a claude-code
```

## Usage

Skills are triggered automatically by keyword matching or can be invoked directly:

```
/github-issue-from-templates
```

Or just describe what you need:

> "Create a bug ticket for the search feature returning stale results"

> "File an accessibility review for the new modal component"

> "I need a ticket to track the API migration work"

## Skill Structure

Each skill follows the [Agent Skills format](https://agentskills.io/):

```bash
skill-name/
└── SKILL.md        # Required Instructions and workflow for the agent
  references/       # Schemas, examples, and reference material
  ...
```

## License

MIT
