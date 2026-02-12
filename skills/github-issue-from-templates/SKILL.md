---
name: github-issue-from-templates
description: Create GitHub issues using data-driven templates. Supports any issue type via configurable template configs. Use when the user asks to create a GitHub ticket, issue, or support ticket, or when they want to add a new issue template.
---

# GitHub Issue Creation — Data-Driven Workflow Engine

This skill creates GitHub issues by dynamically fetching field definitions from GitHub issue templates at runtime. Template metadata (triggers, labels, defaults, formatting rules) is stored in per-template JSON config files under `assets/`. The skill itself contains no hardcoded field definitions.

## File Structure

```
~/.claude/skills/github-issue-from-templates/
  SKILL.md                    # This file — generic workflow engine
  references/
    schema.json               # JSON Schema for template config files
  assets/
    *.json                    # Template configs (one per issue type)
```

---

## Workflow

### Step 1: Template Selection

1. Read all `.json` files from `~/.claude/skills/github-issue-from-templates/assets/`.
2. For each config, compare the user's request against `triggers.keywords` (case-insensitive substring match) and `triggers.description`.
3. **Single match**: Proceed with that template. Confirm the selection with the user briefly (e.g., "I'll use the [template name] template.").
4. **Multiple matches**: Present the matching templates by `name` and `description` and ask the user to choose.
5. **No match**: Present all available templates by `name` and `description` and ask the user to choose.

### Step 2: Fetch Template from GitHub

Use the GitHub MCP `get_file_contents` tool to fetch the template file:

```
owner: <config.repository.owner>
repo:  <config.repository.repo>
path:  <config.templateSource.path>
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
**Project**: [project board name] → [status]

**Body**:
[rendered body preview]
```

Ask for confirmation or edits. If the user requests changes, apply them and re-preview.

### Step 6: Create Issue

Use GitHub MCP `issue_write` with:
```
method: create
owner: <config.repository.owner>
repo: <config.repository.repo>
title: <composed title>
body: <composed body>
labels: <label array>
assignees: <assignee array>
```

### Step 7: Post-Creation

Display the result using `config.postCreation.displayFormat`, substituting `{issueNumber}` and `{issueUrl}` with actual values.

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

### Template fetch failure
If `get_file_contents` fails:
- Notify the user that the template could not be fetched
- Suggest checking repository access permissions
- Offer to create the issue manually without template structure

### JSON config parse failure
If a template config file is malformed:
- Skip that template during selection
- Notify the user which config failed to parse

### GitHub MCP failure (issue creation)
If `issue_write` fails:
1. Stop the operation immediately
2. Notify the user of the failure
3. Provide context about potential causes: authentication token issues, permissions, rate limits, invalid repository access
4. Offer to display the composed issue body so the user can create it manually

---

## Adding a New Template

To add support for a new issue type:

1. Create a new `.json` file in `~/.claude/skills/github-issue-from-templates/assets/`
2. Follow the schema defined in `references/schema.json`
3. Set `repository.owner` and `repository.repo` to the target GitHub repository
4. Set `templateSource.path` to the repo-relative path of the GitHub issue template
5. Set `templateSource.format` to `yml` or `md` based on the template type
6. Define `triggers.keywords` for automatic template matching
7. Add any `fieldDefaults`, `fieldSkipConditions`, label rules, and formatting overrides
8. No changes to this SKILL.md file are needed

---

## Section Formatting Conventions

- Use `no response` for any section where no information was provided — never omit sections
- Include all template sections in the exact order they appear in the fetched template
- Use bullet points for lists
- Use proper markdown formatting
- Label names: lowercase with hyphens (e.g., `document-status`, `bmt-team-2`)
